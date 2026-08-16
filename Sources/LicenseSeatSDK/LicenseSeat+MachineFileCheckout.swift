//
//  LicenseSeat+MachineFileCheckout.swift
//  LicenseSeatSDK
//
//  Request construction, bounds checking, and commit rules for checkout.
//

import Foundation

// MARK: - Internals

extension LicenseSeat {

    /// The fingerprint a machine-file request or verification is bound to.
    ///
    /// An explicit value wins, then the cached activation, then this
    /// installation's stable identifier. Falling back to the cached activation
    /// keeps pre-floor fingerprints usable instead of stranding a seat that
    /// was consumed by an older SDK release.
    func resolveMachineFileFingerprint(_ fingerprint: String?) -> String {
        if let fingerprint, !fingerprint.isEmpty {
            return fingerprint
        }
        if let deviceId = cache.getLicense()?.deviceId, !deviceId.isEmpty {
            return deviceId
        }
        return config.deviceIdentifier ?? ((try? DeviceIdentifier.generate()) ?? "")
    }

    func performMachineFileCheckout(
        licenseKey: String,
        options: MachineFileCheckoutOptions,
        requestID: UUID
    ) async throws -> MachineFile {
        guard let productSlug = config.productSlug else {
            throw LicenseSeatError.productSlugRequired
        }
        guard config.apiKey != nil else {
            throw LicenseSeatError.apiKeyRequired
        }
        try validateRequestIdentity(productSlug: productSlug, licenseKey: licenseKey)
        try validateMachineFileCheckoutOptions(options)
        let fingerprint = try resolveCheckoutFingerprint(options)

        let cachedIdentity = cache.getLicense()
            .flatMap { license -> CachedLicenseIdentity? in
                guard license.licenseKey == licenseKey,
                      license.deviceId == fingerprint else {
                    return nil
                }
                return CachedLicenseIdentity(license)
            }

        eventBus.emit("machineFile:fetching", ["licenseKey": licenseKey])

        let response: MachineFileResponse = try await apiClient.post(
            pathComponents: ["products", productSlug, "licenses", "machine-file"],
            body: machineFileRequestBody(
                licenseKey: licenseKey,
                fingerprint: fingerprint,
                options: options
            )
        )
        try ensureCurrentMachineFileRequest(requestID)

        let machineFile = response.machineFile
        guard !machineFile.certificate.isEmpty,
              machineFile.algorithm == MachineFile.algorithmIdentifier,
              Self.constantTimeEqual(machineFile.licenseKey, licenseKey),
              Self.constantTimeEqual(machineFile.fingerprint, fingerprint) else {
            throw APIError.localFailure(
                code: "invalid_response",
                message: "Machine-file response did not match the requested license or installation"
            )
        }

        try await resolveMachineFileSigningKey(for: machineFile)
        try ensureCurrentMachineFileRequest(requestID)

        let verification = try inspectMachineFile(
            machineFile,
            licenseKey: licenseKey,
            fingerprint: fingerprint
        )
        guard verification.valid else {
            throw LicenseSeatError.validationFailed(
                reason: verification.code ?? "verification_failed"
            )
        }

        // Only commit when this installation still holds the exact activation
        // the request was made for. A late response must never overwrite the
        // artifact belonging to a newer activation.
        if let cachedIdentity {
            guard cachedLicenseMatches(cachedIdentity) else {
                throw CancellationError()
            }
            guard cache.setMachineFile(machineFile) else {
                throw LicenseSeatError.cacheError
            }
        }
        return machineFile
    }

    /// A superseded request must never commit. Both the request generation and
    /// task cancellation are checked at each commit-adjacent boundary.
    private func ensureCurrentMachineFileRequest(_ requestID: UUID) throws {
        try Task.checkCancellation()
        guard currentOfflineSyncRequestID == requestID else {
            throw CancellationError()
        }
    }

    /// Fetch and cache the certificate's signing key when it has not been seen
    /// before, so a rotated key does not look like a forged artifact.
    private func resolveMachineFileSigningKey(for machineFile: MachineFile) async throws {
        guard let keyId = machineFileKeyId(machineFile) else {
            throw APIError.localFailure(
                code: "invalid_response",
                message: "Machine-file certificate could not be parsed"
            )
        }
        guard cache.getPublicKey(keyId) == nil else { return }

        let publicKey = try await getSigningKey(keyId: keyId)
        guard cache.setPublicKey(keyId, publicKey) else {
            throw LicenseSeatError.cacheError
        }
    }

    private func resolveCheckoutFingerprint(
        _ options: MachineFileCheckoutOptions
    ) throws -> String {
        let requested = try selectFingerprintAlias(options)
        let fingerprint = requested ?? resolveMachineFileFingerprint(nil)
        // An explicit alias was already held to the strict floor above. The
        // fallback resolved from the cached activation is exempt from it.
        try validateFingerprint(
            fingerprint,
            allowLegacyShortValue: requested == nil
        )
        return fingerprint
    }

    private func validateMachineFileCheckoutOptions(
        _ options: MachineFileCheckoutOptions
    ) throws {
        try validateMachineFileTTL(options.ttlDays)
        try validateMachineFileGracePeriod(options.gracePeriodDays)
        try validateFingerprintComponents(options.fingerprintComponents)
    }

    private func machineFileRequestBody(
        licenseKey: String,
        fingerprint: String,
        options: MachineFileCheckoutOptions
    ) -> [String: Any] {
        var body: [String: Any] = [
            "fingerprint": fingerprint,
            "device_id": fingerprint,
            "device_fingerprint": fingerprint,
            "license_key": licenseKey
        ]
        if let ttlDays = options.ttlDays {
            body["ttl"] = ttlDays
        }
        if let gracePeriodDays = options.gracePeriodDays {
            body["grace_period"] = gracePeriodDays
        }
        if !options.fingerprintComponents.isEmpty {
            body["fingerprint_components"] = options.fingerprintComponents
        }
        if options.includeLicense {
            body["include"] = ["license"]
        }
        return body
    }

    /// Accept the canonical field or either legacy alias, but never a
    /// disagreement between them.
    private func selectFingerprintAlias(
        _ options: MachineFileCheckoutOptions
    ) throws -> String? {
        let supplied = [
            options.fingerprint,
            options.deviceId,
            options.deviceFingerprint
        ].compactMap { $0 }
        for value in supplied {
            try validateFingerprint(value, allowLegacyShortValue: false)
        }
        guard let selected = supplied.first else { return nil }
        guard supplied.allSatisfy({ $0 == selected }) else {
            throw APIError.localFailure(
                code: "invalid_identity",
                message: "fingerprint, device_id, and device_fingerprint must match "
                    + "when more than one alias is provided"
            )
        }
        return selected
    }

    private func validateMachineFileTTL(_ ttlDays: Int?) throws {
        guard let ttlDays else { return }
        guard ttlDays > 0, ttlDays <= 36_600 else {
            throw APIError.localFailure(
                code: "invalid_identity",
                message: "ttlDays must be between 1 and 36600 when provided"
            )
        }
    }

    private func validateMachineFileGracePeriod(_ gracePeriodDays: Int?) throws {
        guard let gracePeriodDays else { return }
        guard (0...30).contains(gracePeriodDays) else {
            throw APIError.localFailure(
                code: "invalid_identity",
                message: "gracePeriodDays must be between 0 and 30 when provided"
            )
        }
    }

    private func validateFingerprintComponents(
        _ components: [String: String]
    ) throws {
        guard components.count <= MachineFileFormat.maxFingerprintComponents,
              components.allSatisfy({ key, value in
                  MachineFileFormat.safeText(
                      key,
                      maximumBytes: MachineFileFormat.maxComponentKeyBytes
                  ) && MachineFileFormat.safeText(
                      value,
                      maximumBytes: MachineFileFormat.maxComponentValueBytes
                  )
              }) else {
            throw APIError.localFailure(
                code: "invalid_identity",
                message: "fingerprint components are invalid"
            )
        }
    }
}
