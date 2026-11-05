//
//  LicenseSeat+AuthoritativeDenial.swift
//  LicenseSeatSDK
//
//  Authoritative, non-revoking denials (version / product / feature) must
//  never be overruled by a signed offline grant, and must never purge it.
//

import Foundation

extension LicenseSeat {

    static func isAuthoritativeDenialCode(_ code: String?) -> Bool {
        guard let code = code?.lowercased() else { return false }
        return APIError.authoritativeDenialCodes.contains(code)
    }

    /// The persisted online decision for the cached activation is an
    /// authoritative denial that still applies to this process.
    ///
    /// A `version_not_entitled` denial stops applying when the app now
    /// reports a version the denied license's `updates` ceiling covers (the
    /// user rolled back to an entitled version): its offline grant may then be
    /// used again. Every other denial applies until the next online decision.
    func cachedAuthoritativeDenialApplies() -> Bool {
        guard let validation = cache.getLicense()?.validation,
              !validation.valid,
              Self.isAuthoritativeDenialCode(validation.code) else {
            return false
        }
        guard validation.code?.lowercased() == "version_not_entitled" else { return true }
        guard let appVersion = TelemetryPayload.reportedAppVersion(override: config.appVersion),
              let ceiling = validation.license.activeEntitlements
                  .first(where: { $0.key == "updates" })?.belowVersion else {
            return true
        }
        return !Entitlement.versionCovered(appVersion, byCeiling: ceiling)
    }

    /// Record a denial that arrived as an API error (rather than a
    /// `valid: false` validation result) as the cached decision, without
    /// touching the activation or its offline grant.
    func recordAuthoritativeDenial(
        _ error: APIError,
        expectedIdentity: CachedLicenseIdentity
    ) {
        guard cachedLicenseMatches(expectedIdentity),
              let cached = cache.getLicense() else { return }
        let previous = cached.validation?.license
        let license = previous.map {
            LicenseResponse(
                object: $0.object,
                key: $0.key,
                status: $0.status,
                startsAt: $0.startsAt,
                expiresAt: $0.expiresAt,
                mode: $0.mode,
                planKey: $0.planKey,
                seatLimit: $0.seatLimit,
                activeSeats: $0.activeSeats,
                activeEntitlements: $0.activeEntitlements,
                metadata: $0.metadata,
                product: $0.product
            )
        } ?? LicenseResponse(
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
        )
        let denial = ValidationResponse(
            object: "validation_result",
            valid: false,
            code: error.code,
            message: error.message,
            warnings: nil,
            license: license,
            activation: nil
        )
        guard cache.updateValidation(denial) else { return }
        lastOfflineValidation = nil
        recordRuntimeTrust(.failClosedDenial)
        eventBus.emit(.validationFailed, denial)
    }
}
