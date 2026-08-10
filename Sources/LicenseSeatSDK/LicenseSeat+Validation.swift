//
//  LicenseSeat+Validation.swift
//  LicenseSeatSDK
//
//  Online validation and transport-failure recovery.
//

import Foundation

private struct ValidationRequestContext: Sendable {
    let id: UUID
    let productSlug: String
    let deviceId: String?
    let cachedIdentity: LicenseSeat.CachedLicenseIdentity?
}

public extension LicenseSeat {
    /// Validate a license.
    /// - Parameters:
    ///   - licenseKey: License key to validate.
    ///   - options: Validation options.
    /// - Returns: Validation result.
    /// - Throws: ``LicenseSeatError`` or ``APIError`` if validation cannot be completed.
    func validate(
        licenseKey: String,
        options: ValidationOptions = ValidationOptions()
    ) async throws -> ValidationResponse {
        let requestID = UUID()
        currentValidationRequestID = requestID
        defer {
            if currentValidationRequestID == requestID {
                currentValidationRequestID = nil
            }
        }

        let context = try await prepareValidationRequest(
            id: requestID,
            licenseKey: licenseKey,
            options: options
        )
        eventBus.emit("validation:start", ["licenseKey": licenseKey])

        do {
            return try await performOnlineValidation(
                licenseKey: licenseKey,
                context: context
            )
        } catch {
            return try await recoverValidation(
                licenseKey: licenseKey,
                context: context,
                error: error
            )
        }
    }
}

private extension LicenseSeat {
    func prepareValidationRequest(
        id: UUID,
        licenseKey: String,
        options: ValidationOptions
    ) async throws -> ValidationRequestContext {
        await waitForInitialization()
        try ensureCurrentValidationRequest(
            id,
            reason: "A newer license-state operation superseded this validation request."
        )
        guard let productSlug = config.productSlug else {
            throw LicenseSeatError.productSlugRequired
        }
        try validateRequestIdentity(
            productSlug: productSlug,
            licenseKey: licenseKey
        )

        let deviceId = options.deviceId ?? cache.getDeviceId()
        if let deviceId {
            try validateFingerprint(deviceId, allowLegacyShortValue: true)
        }
        let cachedIdentity: CachedLicenseIdentity? = cache.getLicense().flatMap { cachedLicense in
            guard cachedLicense.licenseKey == licenseKey,
                  deviceId == nil || cachedLicense.deviceId == deviceId else {
                return nil
            }
            return CachedLicenseIdentity(cachedLicense)
        }

        return ValidationRequestContext(
            id: id,
            productSlug: productSlug,
            deviceId: deviceId,
            cachedIdentity: cachedIdentity
        )
    }

    func performOnlineValidation(
        licenseKey: String,
        context: ValidationRequestContext
    ) async throws -> ValidationResponse {
        var body: [String: Any] = ["license_key": licenseKey]
        if let deviceId = context.deviceId {
            body["fingerprint"] = deviceId
        }

        let result: ValidationResponse = try await apiClient.post(
            pathComponents: ["products", context.productSlug, "licenses", "validate"],
            body: body
        )

        try verifyValidationResponse(
            result,
            licenseKey: licenseKey,
            productSlug: context.productSlug,
            requestedDeviceId: context.deviceId
        )
        try ensureCurrentValidationRequest(
            context.id,
            reason: "A newer validation request superseded this response."
        )
        try persistValidationResult(result, context: context)
        return result
    }

    func verifyValidationResponse(
        _ result: ValidationResponse,
        licenseKey: String,
        productSlug: String,
        requestedDeviceId: String?
    ) throws {
        guard result.object == "validation_result",
              result.license.object == "license",
              result.license.key == licenseKey,
              result.license.product.slug == productSlug else {
            throw LicenseSeatError.validationFailed(
                reason: "The validation response did not match the requested license or product."
            )
        }

        guard !result.valid ||
                result.license.status.caseInsensitiveCompare("active") == .orderedSame else {
            throw LicenseSeatError.validationFailed(
                reason: "The server marked a non-active license as valid."
            )
        }

        guard let activation = result.activation else { return }
        guard activation.licenseKey == licenseKey,
              requestedDeviceId == nil || activation.deviceId == requestedDeviceId else {
            throw LicenseSeatError.validationFailed(
                reason: "The validation response contained an activation for a different license or device."
            )
        }
    }

    func persistValidationResult(
        _ result: ValidationResponse,
        context: ValidationRequestContext
    ) throws {
        let validatesCachedLicense = context.cachedIdentity.map(cachedLicenseMatches) ?? false
        if validatesCachedLicense {
            // An online invalid result is authoritative. Remove the old signed
            // grant before persisting that state so relaunch cannot resurrect
            // a revoked, suspended, or expired activation offline.
            if !result.valid {
                cache.clearOfflineToken()
            }
            guard cache.updateValidation(result) else {
                throw LicenseSeatError.cacheError
            }
            lastOfflineValidation = nil
        }

        if result.valid {
            // The server just accepted an authenticated validation, so the
            // current local time is the best available trust anchor.
            // Re-anchoring (possibly lowering) recovers a watermark poisoned
            // by a transiently future-set clock. See
            // `LicenseCache.anchorLastSeenTimestamp(_:)`.
            guard cache.anchorLastSeenTimestamp(Date().timeIntervalSince1970) else {
                throw LicenseSeatError.cacheError
            }
            eventBus.emit("validation:success", result)
            return
        }

        eventBus.emit("validation:failed", result)
        guard validatesCachedLicense else { return }
        cancelBackgroundLicenseOperations()
        stopAutoValidation()
        stopHeartbeat()
        stopOfflineRefresh()
        currentAutoLicenseKey = nil
    }

    func recoverValidation(
        licenseKey: String,
        context: ValidationRequestContext,
        error: Error
    ) async throws -> ValidationResponse {
        try ensureCurrentValidationRequest(
            context.id,
            reason: "A newer validation request superseded this failure."
        )
        eventBus.emit("validation:error", ["licenseKey": licenseKey, "error": error])

        if let apiError = error as? APIError,
           apiError.invalidatesCachedLicense,
           let cachedIdentity = context.cachedIdentity {
            handleAuthoritativeInvalidation(apiError, expectedIdentity: cachedIdentity)
            throw error
        }

        guard shouldFallbackToOffline(error: error),
              let cachedIdentity = context.cachedIdentity,
              cachedLicenseMatches(cachedIdentity) else {
            throw error
        }

        let offlineResult = await verifyCachedOffline()
        try ensureCurrentValidationRequest(
            context.id,
            reason: "A newer validation request superseded the offline fallback."
        )
        guard cachedLicenseMatches(cachedIdentity) else {
            throw LicenseSeatError.validationFailed(
                reason: "The cached activation changed during offline validation."
            )
        }
        guard cache.updateValidation(
            offlineResult,
            markValidatedOnline: false
        ) else {
            if !offlineResult.valid {
                lastOfflineValidation = offlineResult
                eventBus.emit("validation:offline-failed", offlineResult)
            }
            throw LicenseSeatError.cacheError
        }

        if offlineResult.valid {
            if lastOfflineValidation?.valid != true {
                eventBus.emit("validation:offline-success", offlineResult)
            }
            lastOfflineValidation = offlineResult
            return offlineResult
        }

        lastOfflineValidation = offlineResult
        eventBus.emit("validation:offline-failed", offlineResult)
        throw error
    }

    func ensureCurrentValidationRequest(_ id: UUID, reason: String) throws {
        guard currentValidationRequestID == id else {
            throw LicenseSeatError.validationFailed(reason: reason)
        }
    }
}
