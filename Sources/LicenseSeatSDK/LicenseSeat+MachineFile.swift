//
//  LicenseSeat+MachineFile.swift
//  LicenseSeatSDK
//
//  Machine-file checkout, local verification, and cached artifact access.
//

import Foundation

// MARK: - Checkout Options

/// Full request options for ``LicenseSeat/checkoutMachineFile(licenseKey:options:)``.
///
/// `fingerprint` is the canonical field. `deviceId` and `deviceFingerprint`
/// exist only because the API accepts those legacy aliases; when more than one
/// is supplied they must agree, so a caller cannot request an artifact for one
/// device while binding it to another.
public struct MachineFileCheckoutOptions: Sendable {
    /// Preferred canonical fingerprint.
    public var fingerprint: String?

    /// Legacy `device_id` alias.
    public var deviceId: String?

    /// Legacy `device_fingerprint` alias.
    public var deviceFingerprint: String?

    /// Requested lifetime in days. The server clamps this to plan and global
    /// maximums, so the issued artifact may be shorter than requested.
    public var ttlDays: Int?

    /// Requested grace period in days after expiry (0...30).
    public var gracePeriodDays: Int?

    /// Whether license data should be embedded in the encrypted payload.
    public var includeLicense: Bool

    /// Optional structured fingerprint components recorded on the activation.
    public var fingerprintComponents: [String: String]

    public init(
        fingerprint: String? = nil,
        deviceId: String? = nil,
        deviceFingerprint: String? = nil,
        ttlDays: Int? = nil,
        gracePeriodDays: Int? = nil,
        includeLicense: Bool = true,
        fingerprintComponents: [String: String] = [:]
    ) {
        self.fingerprint = fingerprint
        self.deviceId = deviceId
        self.deviceFingerprint = deviceFingerprint
        self.ttlDays = ttlDays
        self.gracePeriodDays = gracePeriodDays
        self.includeLicense = includeLicense
        self.fingerprintComponents = fingerprintComponents
    }
}

// MARK: - Public API

public extension LicenseSeat {

    /// The cached machine file, if one has been checked out on this device.
    var currentMachineFile: MachineFile? {
        cache.getMachineFile()
    }

    /// The signing-key id embedded in the cached machine-file certificate.
    ///
    /// The id selects which public key to verify with. It carries no authority
    /// on its own — a certificate is only trusted once its signature verifies
    /// against the key that id resolves to.
    var currentMachineFileKeyId: String? {
        currentMachineFile.flatMap { machineFileKeyId($0) }
    }

    /// Check out a machine file for a license.
    ///
    /// The device must already be activated: machine files are issued against
    /// an existing activation and never consume a seat themselves. A server
    /// response is verified locally before it is allowed to replace the cached
    /// artifact, so a malformed or mismatched response cannot poison working
    /// offline recovery.
    ///
    /// - Parameters:
    ///   - licenseKey: The license key to check out an artifact for.
    ///   - fingerprint: Device fingerprint. Defaults to the cached activation's.
    ///   - ttlDays: Requested lifetime in days; the server clamps it.
    /// - Returns: The verified machine file.
    @discardableResult
    func checkoutMachineFile(
        licenseKey: String,
        fingerprint: String? = nil,
        ttlDays: Int? = nil
    ) async throws -> MachineFile {
        try await checkoutMachineFile(
            licenseKey: licenseKey,
            options: MachineFileCheckoutOptions(
                fingerprint: fingerprint,
                ttlDays: ttlDays
            )
        )
    }

    /// Check out a machine file with full request options.
    @discardableResult
    func checkoutMachineFile(
        licenseKey: String,
        options: MachineFileCheckoutOptions
    ) async throws -> MachineFile {
        let requestID = UUID()
        currentOfflineSyncRequestID = requestID
        defer {
            if currentOfflineSyncRequestID == requestID {
                currentOfflineSyncRequestID = nil
            }
        }

        await waitForInitialization()
        guard currentOfflineSyncRequestID == requestID else {
            throw CancellationError()
        }

        do {
            let machineFile = try await performMachineFileCheckout(
                licenseKey: licenseKey,
                options: options,
                requestID: requestID
            )
            eventBus.emit("machineFile:fetched", ["licenseKey": licenseKey])
            eventBus.emit("machineFile:ready", [
                "kid": machineFileKeyId(machineFile) ?? "",
                "expiresAt": machineFile.expiresAt as Any
            ])
            return machineFile
        } catch {
            log("Machine-file checkout failed:", LogRedaction.describe(error))
            eventBus.emit("machineFile:fetchError", [
                "licenseKey": licenseKey,
                "error": error
            ])
            throw error
        }
    }

    /// Verify a machine file locally and emit the machine-file verification
    /// events.
    ///
    /// - Parameters:
    ///   - machineFile: The artifact to verify.
    ///   - publicKeyB64: Optional public key override. Defaults to the cached
    ///     signing key for the certificate's key id.
    ///   - licenseKey: Optional license key override. Defaults to the
    ///     artifact's own relationship, then the cached activation.
    ///   - fingerprint: Optional fingerprint override. Defaults to the cached
    ///     activation's device id, then this installation's identifier.
    /// - Returns: A result whose `payload` is populated only when valid.
    /// - Throws: ``LicenseSeatError`` when the SDK is not configured well
    ///   enough to attempt verification at all. A file that simply fails to
    ///   verify returns an invalid result rather than throwing.
    @discardableResult
    func verifyMachineFile(
        _ machineFile: MachineFile,
        publicKeyB64: String? = nil,
        licenseKey: String? = nil,
        fingerprint: String? = nil
    ) throws -> MachineFileVerificationResult {
        let result = try inspectMachineFile(
            machineFile,
            publicKeyB64: publicKeyB64,
            licenseKey: licenseKey,
            fingerprint: fingerprint
        )
        let keyId = machineFileKeyId(machineFile) ?? ""
        if result.valid {
            log("Machine file VERIFIED successfully client-side.")
            eventBus.emit("machineFile:verified", ["kid": keyId])
        } else {
            log("Machine file INVALID client-side.")
            eventBus.emit("machineFile:verificationFailed", [
                "kid": keyId,
                "code": result.code ?? "verification_failed"
            ])
        }
        return result
    }

    /// Verify a machine file locally without emitting events.
    ///
    /// Identical to ``verifyMachineFile(_:publicKeyB64:licenseKey:fingerprint:)``
    /// in every check it performs; use it when verification is an internal step
    /// rather than an observable lifecycle transition.
    func inspectMachineFile(
        _ machineFile: MachineFile,
        publicKeyB64: String? = nil,
        licenseKey: String? = nil,
        fingerprint: String? = nil
    ) throws -> MachineFileVerificationResult {
        guard let productSlug = config.productSlug else {
            throw LicenseSeatError.productSlugRequired
        }

        let cachedLicense = cache.getLicense()
        let resolvedLicenseKey = licenseKey.flatMap { $0.isEmpty ? nil : $0 }
            ?? (machineFile.licenseKey.isEmpty ? nil : machineFile.licenseKey)
            ?? cachedLicense?.licenseKey
        guard let resolvedLicenseKey else {
            throw LicenseSeatError.validationFailed(reason: "license_key is required")
        }
        let resolvedFingerprint = resolveMachineFileFingerprint(fingerprint)

        guard let keyId = machineFileKeyId(machineFile) else {
            return MachineFileVerificationResult(
                valid: false,
                code: "invalid_machine_file",
                message: "Machine file certificate could not be parsed"
            )
        }
        guard let publicKey = publicKeyB64.flatMap({ $0.isEmpty ? nil : $0 })
            ?? cache.getPublicKey(keyId) else {
            throw LicenseSeatError.invalidPublicKey
        }

        do {
            let payload = try verifyMachineFileArtifact(
                machineFile,
                context: MachineFileVerificationContext(
                    licenseKey: resolvedLicenseKey,
                    fingerprint: resolvedFingerprint,
                    publicKeyB64: publicKey,
                    productSlug: productSlug
                )
            )
            // A verified artifact must describe the activation this
            // installation actually holds. Otherwise a signed file issued for
            // a different activation of the same license and device — for
            // example one restored after a re-activation — would keep granting
            // access under the current activation's identity.
            if let cachedLicense,
               Self.constantTimeEqual(cachedLicense.licenseKey, resolvedLicenseKey),
               Self.constantTimeEqual(cachedLicense.deviceId, resolvedFingerprint),
               !Self.constantTimeEqual(cachedLicense.activationId, payload.machineId) {
                return MachineFileVerificationResult(
                    valid: false,
                    code: "activation_mismatch",
                    message: "Machine file was issued for a different activation"
                )
            }
            return MachineFileVerificationResult(valid: true, payload: payload)
        } catch let failure as MachineFileVerificationFailure {
            return MachineFileVerificationResult(
                valid: false,
                code: failure.code,
                message: failure.message
            )
        }
    }
}
