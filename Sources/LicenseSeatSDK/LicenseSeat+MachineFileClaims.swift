//
//  LicenseSeat+MachineFileClaims.swift
//  LicenseSeatSDK
//
//  Structural bounds, lifetime consistency, and authorization claims.
//

import Foundation

extension LicenseSeat {

    // MARK: - Entry Point

    /// Bind the decrypted payload to this device, this license, this product,
    /// and this instant. Every branch is a rejection: nothing here can widen a
    /// grant, only refuse one.
    func validateMachineFileClaims(
        _ payload: MachineFilePayload,
        envelopeKeyId: String,
        context: MachineFileVerificationContext
    ) throws {
        try validateMachineIdentityClaims(
            payload,
            envelopeKeyId: envelopeKeyId,
            context: context
        )
        try validateMachineLifetimeClaims(payload, context: context)
        try validateMachineOfflinePolicy(payload, now: context.now)
        try validateIncludedMachineLicense(payload, context: context)
    }

    // MARK: - Identity

    private func validateMachineIdentityClaims(
        _ payload: MachineFilePayload,
        envelopeKeyId: String,
        context: MachineFileVerificationContext
    ) throws {
        guard payload.schemaVersion == MachineFileFormat.schemaVersion,
              !payload.keyId.isEmpty,
              MachineFileFormat.constantTimeEqual(payload.keyId, envelopeKeyId),
              !payload.licenseKey.isEmpty,
              MachineFileFormat.constantTimeEqual(payload.licenseKey, context.licenseKey),
              !payload.machineId.isEmpty,
              !payload.fingerprint.isEmpty,
              safeMachinePayload(payload),
              machineTimeClaimsAreValid(payload) else {
            throw MachineFileVerificationFailure(
                code: "invalid_machine_file_claims",
                message: "Machine file claims are invalid"
            )
        }

        guard !payload.productSlug.isEmpty,
              MachineFileFormat.constantTimeEqual(
                  payload.productSlug,
                  context.productSlug
              ) else {
            throw MachineFileVerificationFailure(
                code: "product_mismatch",
                message: "Machine file was issued for a different product"
            )
        }

        guard MachineFileFormat.constantTimeEqual(
            payload.fingerprint,
            context.fingerprint
        ) else {
            throw MachineFileVerificationFailure(
                code: "fingerprint_mismatch",
                message: "Machine file was issued for a different device"
            )
        }
    }

    // MARK: - Lifetime

    private func validateMachineLifetimeClaims(
        _ payload: MachineFilePayload,
        context: MachineFileVerificationContext
    ) throws {
        let nowUnix = Int(context.now.timeIntervalSince1970)
        let skew = offlineClockSkewSeconds(nowUnix: nowUnix)

        guard payload.iat <= nowUnix + skew else {
            throw MachineFileVerificationFailure(
                code: "clock_tamper",
                message: "Machine file was issued in the future"
            )
        }
        guard payload.nbf <= nowUnix + skew else {
            throw MachineFileVerificationFailure(
                code: "token_not_yet_valid",
                message: "Machine file is not yet valid"
            )
        }
        // The signed grace period is honored here and nowhere else: it extends
        // the artifact deadline, it does not relax any other claim.
        guard nowUnix < payload.exp + payload.gracePeriod else {
            throw MachineFileVerificationFailure(
                code: "token_expired",
                message: "Machine file has expired"
            )
        }
        if let licenseExpiresAt = payload.licenseExpiresAt, nowUnix >= licenseExpiresAt {
            throw MachineFileVerificationFailure(
                code: "license_expired",
                message: "License has expired"
            )
        }
    }

    /// Host policy cap on offline age, plus the clock-rollback watermark
    /// shared with the offline-token path.
    private func validateMachineOfflinePolicy(
        _ payload: MachineFilePayload,
        now: Date
    ) throws {
        let nowUnix = Int(now.timeIntervalSince1970)
        let skew = offlineClockSkewSeconds(nowUnix: nowUnix)
        do {
            try validateMaximumOfflineAge(
                issuedAt: payload.iat,
                nowUnix: nowUnix,
                clockSkewSeconds: skew
            )
            try persistOfflineClockState(now: now, clockSkewSeconds: skew)
        } catch let failure as OfflineVerificationFailure {
            throw MachineFileVerificationFailure(
                code: failure.code,
                message: "Machine file failed offline policy checks: \(failure.code)"
            )
        }
    }

    // MARK: - Included License

    private func validateIncludedMachineLicense(
        _ payload: MachineFilePayload,
        context: MachineFileVerificationContext
    ) throws {
        guard let license = payload.license else { return }
        let nowUnix = Int(context.now.timeIntervalSince1970)
        let startsAfterNow = license.startsAt
            .map { nowUnix < Int($0.timeIntervalSince1970) } ?? false
        let alreadyExpired = license.expiresAt
            .map { nowUnix >= Int($0.timeIntervalSince1970) } ?? false
        guard license.object == "license",
              MachineFileFormat.constantTimeEqual(license.key, context.licenseKey),
              license.status.caseInsensitiveCompare("active") == .orderedSame,
              MachineFileFormat.constantTimeEqual(
                  license.product.slug,
                  context.productSlug
              ),
              !startsAfterNow,
              !alreadyExpired else {
            throw MachineFileVerificationFailure(
                code: "included_license_mismatch",
                message: "Included license does not authorize this device"
            )
        }
    }

    // MARK: - Structural Bounds

    /// Reject any payload whose identifiers, sizes, or shapes fall outside the
    /// bounds the issuer is documented to produce.
    private func safeMachinePayload(_ payload: MachineFilePayload) -> Bool {
        let componentsAreSafe = payload.fingerprintComponents.count
            <= MachineFileFormat.maxFingerprintComponents
            && payload.fingerprintComponents.allSatisfy { key, value in
                MachineFileFormat.safeText(
                    key,
                    maximumBytes: MachineFileFormat.maxComponentKeyBytes
                ) && MachineFileFormat.safeText(
                    value,
                    maximumBytes: MachineFileFormat.maxComponentValueBytes
                )
            }
        let sdkVersionIsSafe = payload.sdkVersion.map {
            MachineFileFormat.safeText(
                $0,
                maximumBytes: MachineFileFormat.maxIdentityBytes
            )
        } ?? true
        let optionalTextIsSafe = sdkVersionIsSafe
            && (payload.deviceName.isEmpty || MachineFileFormat.safeText(
                payload.deviceName,
                maximumBytes: MachineFileFormat.maxIdentityBytes
            ))
            && (payload.platform.isEmpty || MachineFileFormat.safeText(
                payload.platform,
                maximumBytes: MachineFileFormat.maxIdentityBytes
            ))

        return MachineFileFormat.safeText(
            payload.licenseKey,
            maximumBytes: MachineFileFormat.maxLicenseKeyBytes
        )
            && MachineFileFormat.safeText(
                payload.productSlug,
                maximumBytes: MachineFileFormat.maxIdentityBytes
            )
            && MachineFileFormat.validKeyId(payload.keyId)
            && MachineFileFormat.safeText(
                payload.machineId,
                maximumBytes: MachineFileFormat.maxIdentityBytes
            )
            && MachineFileFormat.safeText(
                payload.fingerprint,
                maximumBytes: MachineFileFormat.maxIdentityBytes
            )
            && optionalTextIsSafe
            && payload.ttl <= MachineFileFormat.maxLifetimeSeconds
            && (0...MachineFileFormat.maxGraceSeconds).contains(payload.gracePeriod)
            && componentsAreSafe
            && safeMachineMetadata(payload.metadata)
            && safeIncludedLicense(payload.license)
    }

    private func safeIncludedLicense(_ license: LicenseResponse?) -> Bool {
        guard let license else { return true }
        var entitlementKeys = Set<String>()
        let entitlementsAreSafe = license.activeEntitlements.count
            <= MachineFileFormat.maxEntitlements
            && license.activeEntitlements.allSatisfy { entitlement in
                MachineFileFormat.validEntitlementKey(entitlement.key)
                    && entitlementKeys.insert(entitlement.key).inserted
                    && safeMachineMetadata(entitlement.metadata)
            }

        return license.object == "license"
            && MachineFileFormat.safeText(
                license.key,
                maximumBytes: MachineFileFormat.maxLicenseKeyBytes
            )
            && MachineFileFormat.safeText(
                license.product.slug,
                maximumBytes: MachineFileFormat.maxIdentityBytes
            )
            && MachineFileFormat.safeText(
                license.product.name,
                maximumBytes: MachineFileFormat.maxIdentityBytes
            )
            && license.status == "active"
            && MachineFileFormat.licenseModes.contains(license.mode)
            && MachineFileFormat.safeText(
                license.planKey,
                maximumBytes: MachineFileFormat.maxIdentityBytes
            )
            && license.seatLimit != 0
            && entitlementsAreSafe
            && safeMachineMetadata(license.metadata)
    }

    private func safeMachineMetadata(_ metadata: [String: AnyCodable]?) -> Bool {
        guard let metadata else { return true }
        guard metadata.count <= MachineFileFormat.maxMetadataEntries,
              let encoded = try? JSONEncoder().encode(metadata),
              encoded.count <= MachineFileFormat.maxMetadataBytes,
              (try? StrictJSON.validate(encoded, limits: .signedPayload)) != nil else {
            return false
        }
        return true
    }

    /// The signed lifetime must be internally consistent before it can be
    /// compared against the clock. Grace extends an already valid artifact; a
    /// zero-width signed window must never become a grant.
    private func machineTimeClaimsAreValid(_ payload: MachineFilePayload) -> Bool {
        guard [payload.iat, payload.nbf, payload.exp]
            .allSatisfy(MachineFileFormat.isRepresentableTimestamp) else {
            return false
        }
        if let licenseExpiresAt = payload.licenseExpiresAt,
           !MachineFileFormat.isRepresentableTimestamp(licenseExpiresAt) {
            return false
        }
        guard payload.ttl > 0,
              (0...MachineFileFormat.maxGraceSeconds).contains(payload.gracePeriod),
              payload.iat <= payload.nbf,
              payload.nbf < payload.exp,
              payload.exp - payload.iat == payload.ttl else {
            return false
        }
        guard let issued = ISO8601Timestamp.parse(payload.issued),
              let expiry = ISO8601Timestamp.parse(payload.expiry),
              Int(issued.timeIntervalSince1970) == payload.iat,
              Int(expiry.timeIntervalSince1970) == payload.exp else {
            return false
        }
        return true
    }
}
