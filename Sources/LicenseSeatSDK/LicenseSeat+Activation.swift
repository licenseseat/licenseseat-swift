//
//  LicenseSeat+Activation.swift
//  LicenseSeatSDK
//
//  License activation.
//

import Foundation

public extension LicenseSeat {
    /// Activate a license.
    /// - Parameters:
    ///   - licenseKey: The license key to activate.
    ///   - options: Additional activation options.
    /// - Returns: The activated license.
    /// - Throws: ``LicenseSeatError`` or ``APIError`` if activation fails.
    func activate(
        licenseKey: String,
        options: ActivationOptions = ActivationOptions()
    ) async throws -> License {
        let requestID = UUID()
        currentActivationRequestID = requestID
        defer {
            if currentActivationRequestID == requestID {
                currentActivationRequestID = nil
            }
        }

        await waitForInitialization()
        try ensureCurrentActivationRequest(requestID)
        guard let productSlug = config.productSlug else {
            throw LicenseSeatError.productSlugRequired
        }

        let deviceId: String
        do {
            deviceId = try options.deviceId ?? config.deviceIdentifier ?? DeviceIdentifier.generate()
        } catch {
            // Identity acquisition failed (for example a locked Keychain).
            // Propagating the typed error lets the host app ask the user to
            // unlock and retry, instead of silently rotating the installation
            // fingerprint and consuming another licensed seat.
            eventBus.emit("activation:error", ["licenseKey": licenseKey, "error": error])
            throw error
        }
        eventBus.emit("activation:start", ["licenseKey": licenseKey, "deviceId": deviceId])

        do {
            let activation: ActivationResponse = try await apiClient.post(
                pathComponents: ["products", productSlug, "licenses", licenseKey, "activate"],
                body: activationRequestBody(options: options, deviceId: deviceId)
            )
            try Task.checkCancellation()
            try ensureCurrentActivationRequest(requestID)

            let now = Date()
            let license = try makeActivatedLicense(
                from: activation,
                licenseKey: licenseKey,
                productSlug: productSlug,
                deviceId: deviceId,
                validatedAt: now
            )
            try commitActivatedLicense(license, onlineTimestamp: now)
            eventBus.emit("activation:success", license)
            return license
        } catch {
            eventBus.emit("activation:error", ["licenseKey": licenseKey, "error": error])
            throw error
        }
    }
}

private extension LicenseSeat {
    func ensureCurrentActivationRequest(_ id: UUID) throws {
        guard currentActivationRequestID == id else {
            throw LicenseSeatError.activationFailed(
                reason: "A newer license-state operation superseded this activation request."
            )
        }
    }

    func activationRequestBody(
        options: ActivationOptions,
        deviceId: String
    ) -> [String: Any] {
        var body: [String: Any] = ["fingerprint": deviceId]
        if let deviceName = options.deviceName {
            body["device_name"] = deviceName
        }
        if let metadata = options.metadata {
            body["metadata"] = metadata
        }
        return body
    }

    func makeActivatedLicense(
        from activation: ActivationResponse,
        licenseKey: String,
        productSlug: String,
        deviceId: String,
        validatedAt: Date
    ) throws -> License {
        guard activation.object == "activation",
              !activation.id.isEmpty,
              activation.deactivatedAt == nil,
              activation.license.object == "license",
              activation.licenseKey == licenseKey,
              activation.license.key == licenseKey,
              activation.license.product.slug == productSlug,
              activation.deviceId == deviceId else {
            throw LicenseSeatError.activationFailed(
                reason: "The activation response did not match the requested license, product, or device."
            )
        }
        guard activation.license.status.caseInsensitiveCompare("active") == .orderedSame else {
            throw LicenseSeatError.activationFailed(
                reason: "The server returned a \(activation.license.status) license after activation."
            )
        }

        let validation = ValidationResponse(
            object: "validation_result",
            valid: true,
            code: nil,
            message: nil,
            warnings: nil,
            license: activation.license,
            activation: nil
        )
        return License(
            licenseKey: licenseKey,
            deviceId: deviceId,
            activationId: activation.id,
            activatedAt: activation.activatedAt,
            lastValidated: validatedAt,
            validation: validation
        )
    }

    func commitActivatedLicense(_ license: License, onlineTimestamp: Date) throws {
        // Commit the authoritative activation as one state transition. Older
        // validation, heartbeat, or offline-sync responses must not mutate it
        // after their suspension points resume.
        currentValidationRequestID = nil
        currentHeartbeatRequestID = nil
        currentOfflineSyncRequestID = nil
        cancelBackgroundLicenseOperations()
        stopAutoValidation()
        stopHeartbeat()
        stopOfflineRefresh()

        // A committed activation is an authoritative online acceptance, so the
        // clock watermark is re-anchored (possibly lowered) to the observed
        // commit time rather than max()-advanced. See
        // `LicenseCache.anchorLastSeenTimestamp(_:)`.
        guard cache.setLicense(license),
              cache.anchorLastSeenTimestamp(onlineTimestamp.timeIntervalSince1970) else {
            cache.clear()
            throw LicenseSeatError.cacheError
        }
        cache.clearOfflineToken()
        lastOfflineValidation = nil

        startAutoValidation(licenseKey: license.licenseKey)
        startHeartbeat()
        startOfflineAssetSync()
        scheduleOfflineRefresh()
    }
}
