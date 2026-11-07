//
//  LicenseSeat+AuthoritativeDenial.swift
//  LicenseSeatSDK
//
//  Authoritative, non-revoking denials (version / product / feature / seat)
//  must never be overruled by a signed offline grant, and must never purge it.
//

import Foundation

/// The server's authoritative decisions for one activation, kept apart from
/// `License.validation` so that no offline result (for example a rollback
/// launch) can overwrite them.
///
/// Version decisions are kept **per version**: an online acceptance of 2.9.0
/// says nothing about 3.0.1, and a later denial of a version always outranks
/// an earlier acceptance of it. Only versions the server actually checked (the
/// app version this SDK submitted) are recorded either way.
struct AuthoritativeDecisionRecord: Codable, Equatable, Sendable {
    struct Denial: Codable, Equatable, Sendable {
        let code: String
        let message: String?
    }

    let licenseKey: String
    let deviceId: String
    let activationId: String
    /// A denial that does not depend on the app version (not entitled,
    /// product mismatch, seat limit, unsupported license mode).
    var denial: Denial?
    /// Versions the server refused (`version_not_entitled`).
    var deniedVersions: [String] = []
    /// Versions the server accepted online and has not refused since.
    var acceptedVersions: [String] = []
    /// The most recent version denial's own `updates` ceiling, if it carried one.
    var ceiling: String?
    /// The most recent version denial's message, for status display.
    var versionDenialMessage: String?

    init(for license: License) {
        licenseKey = license.licenseKey
        deviceId = license.deviceId
        activationId = license.activationId
    }

    func matches(_ license: License) -> Bool {
        licenseKey == license.licenseKey &&
            deviceId == license.deviceId &&
            activationId == license.activationId
    }

    var isEmpty: Bool {
        denial == nil && deniedVersions.isEmpty && acceptedVersions.isEmpty
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

    /// The version this SDK actually submits with licensing requests, which
    /// is the only version the server's gate can have checked. It travels in
    /// the optional telemetry object, so with telemetry disabled nothing was
    /// checked and no version decision can be inferred.
    var submittedAppVersion: String? {
        config.telemetryEnabled ? reportedAppVersion : nil
    }

    // MARK: - Reading

    /// The decisions for the cached activation: in memory first (survives a
    /// failed protected write), then the persisted record. If neither exists
    /// but the persisted validation itself is an authoritative denial (the
    /// record write failed while the validation write succeeded), a
    /// conservative version-independent denial is synthesized from it.
    func currentAuthoritativeDecisions() -> AuthoritativeDecisionRecord? {
        guard let license = cache.getLicense() else { return nil }
        if let inMemory = authoritativeDenial, inMemory.matches(license) {
            return inMemory
        }
        if let persisted = cache.getAuthoritativeDenial(), persisted.matches(license) {
            return persisted
        }
        if cache.failedReadKeys.contains(LicenseCache.Key.authoritativeDenial) {
            // The decision store exists but cannot be read right now (for
            // example a locked Keychain): unknown is not "no denial".
            var record = AuthoritativeDecisionRecord(for: license)
            record.denial = .init(
                code: "license_storage_unavailable",
                message: "License storage is temporarily unavailable"
            )
            return record
        }
        if let validation = license.validation, !validation.valid,
           Self.isAuthoritativeDenialCode(validation.code),
           let code = validation.code {
            var record = AuthoritativeDecisionRecord(for: license)
            record.denial = .init(code: code.lowercased(), message: validation.message)
            return record
        }
        return nil
    }

    /// Whether an authoritative decision forbids answering from an offline
    /// grant for the cached activation in this process right now.
    func authoritativeDenialApplies() -> Bool {
        authoritativeRefusal() != nil
    }

    /// The refusal that applies now, as (code, message), or `nil`.
    func authoritativeRefusal() -> (code: String, message: String?)? {
        guard let record = currentAuthoritativeDecisions() else { return nil }
        if let denial = record.denial {
            return (denial.code, denial.message)
        }
        guard !record.deniedVersions.isEmpty else { return nil }
        let refusal = ("version_not_entitled", record.versionDenialMessage)
        guard let current = reportedAppVersion else { return refusal }
        if record.deniedVersions.contains(where: { Self.sameVersion($0, current) }) {
            return refusal
        }
        if record.acceptedVersions.contains(where: { Self.sameVersion($0, current) }) {
            return nil
        }
        if let ceiling = record.ceiling,
           let currentCore = Self.serverCoreVersion(current),
           let ceilingCore = Self.serverCoreVersion(ceiling),
           currentCore.lexicographicallyPrecedes(ceilingCore) {
            return nil
        }
        return refusal
    }

    // MARK: - Recording

    /// Record a denial for the activation it was made for. The in-memory
    /// decision is set first, so a failed protected write can never leave the
    /// previous authorization usable in this process; the write's outcome is
    /// returned. Any in-flight SDK artifact refresh is fenced.
    @discardableResult
    func recordAuthoritativeDenial(
        code: String,
        message: String?,
        ceiling: String?,
        for license: License
    ) -> Bool {
        var record = currentDecisionsForWriting(license)
        let normalizedCode = code.lowercased()
        if normalizedCode == "version_not_entitled", let version = submittedAppVersion {
            if !record.deniedVersions.contains(where: { Self.sameVersion($0, version) }) {
                record.deniedVersions.append(version)
            }
            record.acceptedVersions.removeAll { Self.sameVersion($0, version) }
            if let ceiling {
                record.ceiling = ceiling
                // A fresh, restrictive ceiling outranks historical acceptance.
                record.acceptedVersions.removeAll { accepted in
                    guard let acceptedCore = Self.serverCoreVersion(accepted),
                          let ceilingCore = Self.serverCoreVersion(ceiling) else { return true }
                    return !acceptedCore.lexicographicallyPrecedes(ceilingCore)
                }
            }
            record.versionDenialMessage = message
        } else {
            record.denial = .init(code: normalizedCode, message: message)
        }
        authoritativeDenial = record
        currentOfflineSyncRequestID = nil
        lastOfflineValidation = nil
        recordRuntimeTrust(.failClosedDenial)
        return cache.setAuthoritativeDenial(record)
    }

    /// An authoritative online acceptance for the cached activation. It
    /// clears version-independent denials, and accepts exactly the version the
    /// server checked — never others, and nothing when no version was sent.
    @discardableResult
    func recordOnlineAcceptance(for license: License) -> Bool {
        var record = currentDecisionsForWriting(license)
        record.denial = nil
        if let version = submittedAppVersion {
            record.deniedVersions.removeAll { Self.sameVersion($0, version) }
            if !record.acceptedVersions.contains(where: { Self.sameVersion($0, version) }) {
                record.acceptedVersions.append(version)
            }
        }
        authoritativeDenial = record
        return cache.setAuthoritativeDenial(record)
    }

    private func currentDecisionsForWriting(_ license: License) -> AuthoritativeDecisionRecord {
        if let inMemory = authoritativeDenial, inMemory.matches(license) { return inMemory }
        if let persisted = cache.getAuthoritativeDenial(), persisted.matches(license) { return persisted }
        return AuthoritativeDecisionRecord(for: license)
    }

    /// Thrown-denial path: record the decision and a matching `valid: false`
    /// validation for status display, keeping the activation and its grant.
    /// The state transition is always published; a persistence failure is
    /// reported through `sdk:error` (the API error itself is rethrown by the
    /// caller, so the host still sees the refusal).
    func recordThrownAuthoritativeDenial(
        _ error: APIError,
        expectedIdentity: CachedLicenseIdentity
    ) {
        guard cachedLicenseMatches(expectedIdentity),
              let cached = cache.getLicense() else { return }
        let recordPersisted = recordAuthoritativeDenial(
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
        let validationPersisted = cache.updateValidation(denial)
        eventBus.emit(.validationFailed, denial)
        if !recordPersisted || !validationPersisted {
            eventBus.emit(.sdkError, [
                "message": "An authoritative license denial could not be saved; it applies for this session",
                "code": error.code ?? "not_entitled"
            ])
        }
    }

    // MARK: - Server-compatible version comparison

    /// Mirrors the engine's `Semver.parse_lenient` for declared versions:
    /// trims whitespace, drops one leading `v`, accepts full SemVer or `N` /
    /// `N.N` (padded with `.0`, then held to the same strict rules — no
    /// leading zeros). Anything else, including components that overflow, is
    /// `nil` — never proof of coverage.
    static func serverCoreVersion(_ string: String) -> [Int]? {
        guard string.utf8.count <= 255 else { return nil }
        var trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("v") { trimmed.removeFirst() }
        let numeric = "(0|[1-9][0-9]*)"
        let identifier = "(0|[1-9][0-9]*|[0-9]*[a-zA-Z-][0-9a-zA-Z-]*)"
        let prerelease = "(-\(identifier)(\\.\(identifier))*)?"
        let build = "(\\+[0-9a-zA-Z-]+(\\.[0-9a-zA-Z-]+)*)?"
        let semver = "^\(numeric)\\.\(numeric)\\.\(numeric)\(prerelease)\(build)$"
        let core: Substring
        if trimmed.range(of: semver, options: .regularExpression) != nil {
            core = trimmed.split(whereSeparator: { $0 == "-" || $0 == "+" }).first ?? ""
        } else if trimmed.range(of: "^\(numeric)(\\.\(numeric))?$", options: .regularExpression) != nil {
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
