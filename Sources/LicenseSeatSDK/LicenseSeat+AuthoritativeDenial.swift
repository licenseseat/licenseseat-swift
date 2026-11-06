//
//  LicenseSeat+AuthoritativeDenial.swift
//  LicenseSeatSDK
//
//  Authoritative, non-revoking denials (version / product / feature / seat)
//  must never be overruled by a signed offline grant, and must never purge it.
//

import Foundation

/// The server's authoritative refusal for one activation, kept apart from
/// `License.validation` so that no offline result (for example a rollback
/// launch) can overwrite it. Cleared only by a later online success for the
/// same activation, a new activation, or reset/revocation/deactivation.
struct AuthoritativeDenialRecord: Codable, Equatable, Sendable {
    let licenseKey: String
    let deviceId: String
    let activationId: String
    let code: String
    let message: String?
    /// The app version this SDK reported when the denial was received (the
    /// version the server refused), when known.
    let deniedVersion: String?
    /// The `updates` ceiling carried by the denial response itself, when the
    /// server included it. Never copied from older cached metadata.
    let ceiling: String?

    func matches(_ license: License) -> Bool {
        licenseKey == license.licenseKey &&
            deviceId == license.deviceId &&
            activationId == license.activationId
    }
}

/// The last app version the server accepted online for one activation:
/// proof that rolling back to it is entitled, independent of whether the
/// server's later denial carried a ceiling.
struct EntitledVersionRecord: Codable, Equatable, Sendable {
    let licenseKey: String
    let deviceId: String
    let activationId: String
    let version: String

    func matches(_ license: License) -> Bool {
        licenseKey == license.licenseKey &&
            deviceId == license.deviceId &&
            activationId == license.activationId
    }
}

extension LicenseSeat {

    static func isAuthoritativeDenialCode(_ code: String?) -> Bool {
        guard let code = code?.lowercased() else { return false }
        return APIError.authoritativeDenialCodes.contains(code)
    }

    /// The app version reported to the server (what its version gate checks).
    var reportedAppVersion: String? {
        TelemetryPayload.reportedAppVersion(override: config.appVersion)
    }

    /// The denial for the cached activation, if any: the in-memory decision
    /// first (it survives a failed protected write), then the persisted one.
    func currentAuthoritativeDenial() -> AuthoritativeDenialRecord? {
        guard let license = cache.getLicense() else { return nil }
        if let inMemory = authoritativeDenial, inMemory.matches(license) {
            return inMemory
        }
        if let persisted = cache.getAuthoritativeDenial(), persisted.matches(license) {
            return persisted
        }
        return nil
    }

    /// Whether an authoritative denial forbids answering from an offline
    /// grant for the cached activation in this process right now.
    ///
    /// A `version_not_entitled` denial stops applying only with positive
    /// evidence that the app now runs an entitled version, and never for the
    /// refused version itself: either the current version is the last one the
    /// server accepted online for this activation, or the denial's own
    /// ceiling (strictly parsed, server-compatible) covers it.
    func authoritativeDenialApplies() -> Bool {
        guard let denial = currentAuthoritativeDenial() else { return false }
        guard denial.code.lowercased() == "version_not_entitled" else { return true }
        guard let current = reportedAppVersion else { return true }
        if let denied = denial.deniedVersion, Self.sameVersion(current, denied) {
            return true
        }
        if let license = cache.getLicense(),
           let entitled = cache.getEntitledVersion(),
           entitled.matches(license),
           Self.sameVersion(current, entitled.version) {
            return false
        }
        if let ceiling = denial.ceiling,
           let currentCore = Self.serverCoreVersion(current),
           let ceilingCore = Self.serverCoreVersion(ceiling),
           currentCore.lexicographicallyPrecedes(ceilingCore) {
            return false
        }
        return true
    }

    /// Record a denial (from `valid: false`, a thrown error on validate, or a
    /// thrown error on re-activation) for the activation it was made for. The
    /// in-memory decision is set first, so a failed protected write can never
    /// leave the previous authorization usable; the write's outcome is
    /// returned so callers can surface `cacheError`.
    @discardableResult
    func recordAuthoritativeDenial(
        code: String,
        message: String?,
        ceiling: String?,
        for license: License
    ) -> Bool {
        let record = AuthoritativeDenialRecord(
            licenseKey: license.licenseKey,
            deviceId: license.deviceId,
            activationId: license.activationId,
            code: code.lowercased(),
            message: message,
            deniedVersion: reportedAppVersion,
            ceiling: ceiling
        )
        authoritativeDenial = record
        // Fence any in-flight artifact refresh this SDK started: it must not
        // re-store a grant after this decision.
        currentOfflineSyncRequestID = nil
        lastOfflineValidation = nil
        recordRuntimeTrust(.failClosedDenial)
        return cache.setAuthoritativeDenial(record)
    }

    /// An authoritative online acceptance for the cached activation: the
    /// denial no longer applies, and the reported version is proven entitled.
    func recordOnlineAcceptance(for license: License) {
        authoritativeDenial = nil
        cache.clearAuthoritativeDenial()
        if let version = reportedAppVersion {
            cache.setEntitledVersion(EntitledVersionRecord(
                licenseKey: license.licenseKey,
                deviceId: license.deviceId,
                activationId: license.activationId,
                version: version
            ))
        }
    }

    /// Thrown-denial path: persist the decision and a matching `valid: false`
    /// validation for status display, keeping the activation and its grant.
    func recordThrownAuthoritativeDenial(
        _ error: APIError,
        expectedIdentity: CachedLicenseIdentity
    ) {
        guard cachedLicenseMatches(expectedIdentity),
              let cached = cache.getLicense() else { return }
        recordAuthoritativeDenial(
            code: error.code ?? "not_entitled",
            message: error.message,
            ceiling: nil,
            for: cached
        )
        let denial = ValidationResponse(
            object: "validation_result",
            valid: false,
            code: error.code,
            message: error.message,
            warnings: nil,
            license: cached.validation?.license ?? LicenseResponse(
                object: "license",
                key: cached.licenseKey,
                status: "unknown",
                startsAt: nil,
                expiresAt: nil,
                mode: "unknown",
                planKey: "",
                seatLimit: nil,
                activeSeats: 0,
                activeEntitlements: [],
                metadata: nil,
                product: Product(slug: config.productSlug ?? "", name: config.productSlug ?? "")
            ),
            activation: nil
        )
        cache.updateValidation(denial)
        eventBus.emit(.validationFailed, denial)
    }

    // MARK: - Server-compatible version comparison

    /// Mirrors the engine's `Semver.parse_lenient` for declared versions:
    /// trims whitespace, drops one leading `v`, accepts full SemVer or
    /// `N` / `N.N` (padded with zeros). Anything else, including components
    /// that overflow, is `nil` — never proof of coverage.
    static func serverCoreVersion(_ string: String) -> [Int]? {
        guard string.utf8.count <= 255 else { return nil }
        var trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("v") { trimmed.removeFirst() }
        let numeric = "(0|[1-9][0-9]*)"
        let identifier = "(0|[1-9][0-9]*|[0-9]*[a-zA-Z-][0-9a-zA-Z-]*)"
        let semver = "^\(numeric)\\.\(numeric)\\.\(numeric)(-\(identifier)(\\.\(identifier))*)?(\\+[0-9a-zA-Z-]+(\\.[0-9a-zA-Z-]+)*)?$"
        let core: Substring
        if trimmed.range(of: semver, options: .regularExpression) != nil {
            core = trimmed.split(whereSeparator: { $0 == "-" || $0 == "+" }).first ?? ""
        } else if trimmed.range(of: "^[0-9]+(\\.[0-9]+)?$", options: .regularExpression) != nil {
            core = Substring(trimmed)
        } else {
            return nil
        }
        var parts: [Int] = []
        for piece in core.split(separator: ".") {
            guard let value = Int(piece) else { return nil }
            parts.append(value)
        }
        while parts.count < 3 { parts.append(0) }
        return parts.count == 3 ? parts : nil
    }

    /// Two declared versions name the same release: equal core versions when
    /// both parse, otherwise identical trimmed strings.
    static func sameVersion(_ lhs: String, _ rhs: String) -> Bool {
        if let left = serverCoreVersion(lhs), let right = serverCoreVersion(rhs) {
            return left == right
        }
        return lhs.trimmingCharacters(in: .whitespacesAndNewlines) ==
            rhs.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
