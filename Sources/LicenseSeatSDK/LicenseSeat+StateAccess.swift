//
//  LicenseSeat+StateAccess.swift
//  LicenseSeatSDK
//
//  Typed state accessors (#13): restoreLicense, stateSnapshot, and the
//  trusted-decision surface, at parity with the Rust SDK.
//

import Foundation

extension LicenseSeat {
    /// Bind the decision just committed to the activation it was made for.
    func recordRuntimeTrust(_ source: TrustedLicenseSource) {
        guard let license = cache.getLicense() else {
            runtimeTrust = nil
            return
        }
        runtimeTrust = (CachedLicenseIdentity(license), source)
    }

    /// A verified artifact establishes access; a rejected one is a fail-closed
    /// denial. Having no artifact at all is the absence of a verdict, so it
    /// establishes nothing (parity with the Rust SDK's `NoOfflineArtifact`).
    func recordOfflineRuntimeTrust(_ result: ValidationResponse) {
        if result.valid {
            recordRuntimeTrust(.signedOfflineArtifact)
        } else if result.code == "no_offline_token" {
            runtimeTrust = nil
        } else {
            recordRuntimeTrust(.failClosedDenial)
        }
    }

    /// The trust record, only while it still describes the cached activation.
    private var currentRuntimeTrust: TrustedLicenseSource? {
        guard let runtimeTrust, cachedLicenseMatches(runtimeTrust.identity) else {
            return nil
        }
        return runtimeTrust.source
    }

    private func unexpiredEntitlements(of validation: ValidationResponse) -> [Entitlement] {
        let now = authorizationTime()
        return validation.license.activeEntitlements.filter {
            $0.expiresAt.map { $0 >= now } ?? true
        }
    }
}

public extension LicenseSeat {
    /// Whether this process has itself established the current license
    /// decision — from an authenticated online response, a locally verified
    /// signed offline artifact, or a fail-closed denial — for the activation
    /// that is cached right now.
    ///
    /// `false` means the cached state was persisted by an earlier process and
    /// has not been re-established yet (for example right after launch with
    /// no network and no offline artifact). ``getStatus()`` still reports that
    /// persisted state; use this to tell the two apart.
    var isLicenseStateTrusted: Bool {
        currentRuntimeTrust != nil
    }

    /// What established the decision this process trusts, or `nil` when
    /// ``isLicenseStateTrusted`` is `false`.
    var currentTrustedLicenseSource: TrustedLicenseSource? {
        currentRuntimeTrust
    }

    /// The license as last established by this process (online response or
    /// verified offline artifact), with expired entitlements removed. `nil`
    /// when nothing has been established in this process, or when the
    /// established decision is a denial.
    var currentTrustedLicense: LicenseResponse? {
        guard let source = currentRuntimeTrust,
              source != .failClosedDenial,
              let validation = cache.getLicense()?.validation,
              validation.valid else {
            return nil
        }
        let license = validation.license
        return LicenseResponse(
            object: license.object,
            key: license.key,
            status: license.status,
            startsAt: license.startsAt,
            expiresAt: license.expiresAt,
            mode: license.mode,
            planKey: license.planKey,
            seatLimit: license.seatLimit,
            activeSeats: license.activeSeats,
            activeEntitlements: unexpiredEntitlements(of: validation),
            metadata: license.metadata,
            product: license.product
        )
    }

    /// A consistent, typed snapshot of the current license state. Replaces
    /// reading ``getStatus()``, ``currentLicense()``, ``isOnline`` and
    /// friends one by one (or the stringly `LicenseSeatStore.debugReport()`).
    func stateSnapshot() -> LicenseStateSnapshot {
        let status = getStatus()
        let license = cache.getLicense()
        let validation = license?.validation
        let grantsAccess: Bool
        switch status {
        case .active, .offlineValid:
            grantsAccess = true
        default:
            grantsAccess = false
        }
        return LicenseStateSnapshot(
            status: status,
            isOnline: isOnline,
            license: license,
            validation: validation,
            activeEntitlements: grantsAccess
                ? validation.map(unexpiredEntitlements(of:)) ?? []
                : [],
            trustedSource: currentRuntimeTrust,
            lastSeenTimestamp: lastSeenTimestamp(),
            nextAutoValidationAt: nextAutoValidationAt
        )
    }

    /// Re-establish the cached activation, if any, and report the outcome.
    ///
    /// If this process has already re-established access for the cached
    /// activation, that decision is returned without a network request.
    /// Otherwise (nothing established yet, or a denial) the
    /// cached license is validated online; the normal offline-fallback policy
    /// (``LicenseSeatConfig/offlineFallbackMode``) applies when the server is
    /// unreachable, and an authoritative refusal invalidates the cache exactly
    /// as ``validate(licenseKey:options:)`` does. Never throws: failures are
    /// reported in ``RestoreResult/error``.
    func restoreLicense() async -> RestoreResult {
        await waitForInitialization()
        guard let cachedLicense = cache.getLicense() else {
            return RestoreResult(
                restored: false,
                status: getStatus(),
                license: nil,
                validation: nil,
                error: nil
            )
        }

        var validation: ValidationResponse?
        var failure: (any Error)?
        if let source = currentRuntimeTrust, source != .failClosedDenial {
            // Already re-established by this process; no network request.
            validation = cachedLicense.validation
        } else {
            do {
                validation = try await validate(licenseKey: cachedLicense.licenseKey)
            } catch {
                failure = error
            }
        }

        let status = getStatus()
        let restored: Bool
        switch status {
        case .active, .offlineValid:
            restored = true
        default:
            restored = false
        }
        return RestoreResult(
            restored: restored,
            status: status,
            license: cache.getLicense(),
            validation: validation,
            error: failure
        )
    }
}
