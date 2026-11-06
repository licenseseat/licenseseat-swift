//
//  LicenseSeat+Deactivation.swift
//  LicenseSeatSDK
//
//  License deactivation and heartbeat operations.
//

import Foundation

public extension LicenseSeat {
    /// Deactivate the current license
    /// - Throws: ``LicenseSeatError/noActiveLicense`` if no license is active,
    ///   or ``LicenseSeatError/cacheError`` if protected storage could not be
    ///   read (for example a locked Keychain) — not the same as "none".
    /// - Throws: ``APIError`` if server request fails
    func deactivate() async throws {
        await waitForInitialization()
        guard let productSlug = config.productSlug else {
            throw LicenseSeatError.productSlugRequired
        }

        let license = try requireCachedLicense()
        try validateRequestIdentity(
            productSlug: productSlug,
            licenseKey: license.licenseKey
        )
        try validateFingerprint(
            license.deviceId,
            allowLegacyShortValue: true
        )
        currentActivationRequestID = nil
        let requestedIdentity = CachedLicenseIdentity(license)

        eventBus.emit(.deactivationStart, license)

        do {
            let response: DeactivationResponse = try await apiClient.post(
                pathComponents: ["products", productSlug, "licenses", "deactivate"],
                body: [
                    "license_key": license.licenseKey,
                    "fingerprint": license.deviceId
                ]
            )
            guard response.object == "deactivation",
                  response.activationId == license.activationId else {
                throw LicenseSeatError.validationFailed(
                    reason: "The deactivation response did not match the active installation."
                )
            }

            let clearedCurrentState = completeLocalDeactivation(
                matching: requestedIdentity
            )
            eventBus.emit(.deactivationSuccess, [
                "licenseKey": license.licenseKey,
                "localStateCleared": clearedCurrentState
            ])
        } catch {
            if shouldTreatDeactivationAsSuccess(error) {
                let clearedCurrentState = completeLocalDeactivation(
                    matching: requestedIdentity
                )
                eventBus.emit(.deactivationSuccess, [
                    "licenseKey": license.licenseKey,
                    "localStateCleared": clearedCurrentState
                ])
                return
            }
            eventBus.emit(.deactivationError, ["error": error, "license": license])
            throw error
        }
    }

    /// Send a heartbeat for the current license
    /// - Throws: ``LicenseSeatError/productSlugRequired`` if product slug is not configured
    func heartbeat() async throws {
        let requestID = UUID()
        currentHeartbeatRequestID = requestID
        defer {
            if currentHeartbeatRequestID == requestID {
                currentHeartbeatRequestID = nil
            }
        }

        await waitForInitialization()
        guard currentHeartbeatRequestID == requestID else {
            throw LicenseSeatError.validationFailed(
                reason: "A newer license-state operation superseded this heartbeat request."
            )
        }
        guard let productSlug = config.productSlug else {
            throw LicenseSeatError.productSlugRequired
        }

        let license = try requireCachedLicense()
        try validateRequestIdentity(
            productSlug: productSlug,
            licenseKey: license.licenseKey
        )
        try validateFingerprint(
            license.deviceId,
            allowLegacyShortValue: true
        )

        let deviceId = license.deviceId

        let body: [String: Any] = [
            "license_key": license.licenseKey,
            "fingerprint": deviceId
        ]

        do {
            let response: HeartbeatResponse = try await apiClient.post(
                pathComponents: ["products", productSlug, "licenses", "heartbeat"],
                body: body
            )
            guard response.object == "heartbeat",
                  let responseLicense = response.license,
                  responseLicense.object == "license",
                  responseLicense.key == license.licenseKey,
                  responseLicense.product.slug == productSlug,
                  responseLicense.status.caseInsensitiveCompare("active") == .orderedSame else {
                throw LicenseSeatError.validationFailed(
                    reason: "The heartbeat response did not match the active license or product."
                )
            }
            guard currentHeartbeatRequestID == requestID else {
                throw LicenseSeatError.validationFailed(
                    reason: "A newer heartbeat request superseded this response."
                )
            }
            // Heartbeat acceptance is an authoritative online contact:
            // re-anchor (possibly lower) the clock watermark. See
            // `LicenseCache.anchorLastSeenTimestamp(_:)`.
            guard anchorAuthoritativeTime(Date()) else {
                throw LicenseSeatError.cacheError
            }
            lastHeartbeatResponse = response
            lastHeartbeatError = nil

            eventBus.emit(.heartbeatSuccess, [:])
            log("Heartbeat sent successfully")
        } catch {
            guard currentHeartbeatRequestID == requestID else { throw error }
            lastHeartbeatError = error
            if let apiError = error as? APIError,
               apiError.invalidatesCachedLicense {
                handleAuthoritativeInvalidation(
                    apiError,
                    expectedIdentity: CachedLicenseIdentity(license)
                )
            }
            eventBus.emit(.heartbeatError, ["error": error])
            throw error
        }
    }
}

private extension LicenseSeat {
    @discardableResult
    func completeLocalDeactivation(
        matching requestedIdentity: CachedLicenseIdentity
    ) -> Bool {
        guard cachedLicenseMatches(requestedIdentity) else {
            return false
        }
        cancelBackgroundLicenseOperations()
        cache.clearLicense()
        cache.clearOfflineToken()
        cache.clearMachineFile()
        stopAutoValidation()
        stopHeartbeat()
        stopOfflineRefresh()
        currentAutoLicenseKey = nil
        lastOfflineValidation = nil
        runtimeTrust = nil
        authoritativeDenial = nil
        cache.clearAuthoritativeDenial()
        return true
    }

    func shouldTreatDeactivationAsSuccess(_ error: Error) -> Bool {
        guard let apiError = error as? APIError else { return false }
        let code = apiError.code?.lowercased()
        switch apiError.status {
        case 404:
            return code.map {
                ["license_not_found", "activation_not_found", "already_deactivated"]
                    .contains($0)
            } == true
        case 410:
            return true
        case 422:
            return apiError.isLicenseTerminalError || code == "already_deactivated"
        default:
            return false
        }
    }
}
