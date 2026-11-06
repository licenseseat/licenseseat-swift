//
//  LicenseSeat+OfflineArtifacts.swift
//  LicenseSeatSDK
//
//  The cached machine file as an offline authorization source (#14).
//

import Foundation

extension LicenseSeat {

    /// Machine-file verdicts that are final about *time or license state*:
    /// the artifact was examined and says no. An older legacy token must not
    /// override them. Every other failure (missing or rotated key, malformed
    /// or foreign artifact, configuration) means the artifact could not
    /// vouch either way, so the legacy token may still be consulted.
    static let definitiveMachineFileVerdicts: Set<String> = [
        "token_expired", "license_expired", "grace_period_expired",
        "clock_tamper", "token_not_yet_valid", "included_license_mismatch",
        // A correctly signed, activation-bound artifact whose authenticated
        // claims are refused (for example an embedded license that is
        // revoked or suspended) is a verdict, not an inability to vouch.
        "invalid_machine_file_claims"
    ]

    /// Verify the cached machine file against this installation's activation
    /// and convert it into an offline validation result.
    ///
    /// Verification is bound to the *cached activation's* license key and
    /// fingerprint, never to the artifact's own unsigned metadata, so a
    /// restored machine file for another license cannot verify against
    /// itself. `inspectMachineFile` additionally binds the signed machine id
    /// to the cached activation id.
    ///
    /// - Parameter allowNetwork: Whether a missing or rejected signing key may
    ///   be fetched (once) from the authoritative endpoint. Launch-time quick
    ///   verification passes `false`.
    /// - Returns: `nil` only when `allowNetwork` is `false` and the signing key
    ///   is not cached, i.e. when the artifact cannot be examined locally.
    func verifyCachedMachineFileForAuthorization(
        _ machineFile: MachineFile,
        allowNetwork: Bool
    ) async -> ValidationResponse? {
        guard let cachedLicense = cache.getLicense() else {
            return makeOfflineValidationResponse(valid: false, code: "license_mismatch")
        }
        let identity = CachedLicenseIdentity(cachedLicense)
        guard let keyId = machineFileKeyId(machineFile) else {
            return makeOfflineValidationResponse(valid: false, code: "invalid_machine_file")
        }

        var fetched = false
        var publicKey: String
        if let cachedKey = cache.getPublicKey(keyId), isValidEd25519PublicKey(cachedKey) {
            publicKey = cachedKey
        } else {
            guard allowNetwork else { return nil }
            do {
                publicKey = try await getSigningKey(keyId: keyId)
            } catch {
                return makeOfflineValidationResponse(valid: false, code: "no_public_key")
            }
            fetched = true
            // Revocation, reset, or re-activation may have happened while the
            // key request was suspended: never vouch for a stale activation.
            if let superseded = await supersededMachineFileOutcome(machineFile, identity: identity) {
                return superseded
            }
        }

        var result = inspectCachedMachineFile(
            machineFile,
            publicKey: publicKey,
            license: cachedLicense
        )
        // A structurally valid cached key that fails the signature is
        // refreshed exactly once, mirroring the offline-token path. An
        // unverified replacement key is never persisted.
        if case .failure(let code) = result, code == "signature_invalid",
           !fetched, allowNetwork,
           let refreshed = try? await getSigningKey(keyId: keyId) {
            if let superseded = await supersededMachineFileOutcome(machineFile, identity: identity) {
                return superseded
            }
            publicKey = refreshed
            fetched = true
            result = inspectCachedMachineFile(
                machineFile,
                publicKey: publicKey,
                license: cachedLicense
            )
        }

        switch result {
        case .failure(let code):
            return makeOfflineValidationResponse(valid: false, code: code)
        case .success(let payload):
            if fetched, !cache.setPublicKey(keyId, publicKey) {
                return makeOfflineValidationResponse(valid: false, code: "cache_error")
            }
            return makeMachineFileValidationResponse(payload)
        }
    }

    /// After a suspension: `nil` when the same activation still holds the
    /// same machine file. A changed activation never gets a verdict from the
    /// stale one; a machine file replaced by a concurrent refresh is verified
    /// in its place (locally) rather than reported as a denial.
    private func supersededMachineFileOutcome(
        _ machineFile: MachineFile,
        identity: CachedLicenseIdentity
    ) async -> ValidationResponse?? {
        guard cachedLicenseMatches(identity) else {
            return .some(makeOfflineValidationResponse(valid: false, code: "license_mismatch"))
        }
        let current = cache.getMachineFile()
        guard current != machineFile else { return nil }
        guard let current else {
            return .some(makeOfflineValidationResponse(valid: false, code: "license_mismatch"))
        }
        return .some(await verifyCachedMachineFileForAuthorization(current, allowNetwork: false))
    }

    private enum CachedMachineFileOutcome {
        case success(MachineFilePayload)
        case failure(String)
    }

    private func inspectCachedMachineFile(
        _ machineFile: MachineFile,
        publicKey: String,
        license: License
    ) -> CachedMachineFileOutcome {
        do {
            let verification = try inspectMachineFile(
                machineFile,
                publicKeyB64: publicKey,
                licenseKey: license.licenseKey,
                fingerprint: license.deviceId
            )
            guard verification.valid, let payload = verification.payload else {
                return .failure(verification.code ?? "verification_failed")
            }
            return .success(payload)
        } catch LicenseSeatError.productSlugRequired {
            return .failure("invalid_configuration")
        } catch {
            return .failure("verification_error")
        }
    }

    /// Shape a verified machine-file payload like any other offline result,
    /// so status, entitlement checks, and events treat both artifacts alike.
    /// Only signed, verified data is used; when the issuer did not embed the
    /// license, no entitlements are granted from unsigned cached metadata.
    private func makeMachineFileValidationResponse(
        _ payload: MachineFilePayload
    ) -> ValidationResponse {
        let now = authorizationTime()
        let licenseResponse: LicenseResponse
        if let license = payload.license {
            licenseResponse = LicenseResponse(
                object: license.object,
                key: license.key,
                status: license.status,
                startsAt: license.startsAt,
                expiresAt: license.expiresAt,
                mode: license.mode,
                planKey: license.planKey,
                seatLimit: license.seatLimit,
                activeSeats: license.activeSeats,
                activeEntitlements: license.activeEntitlements.filter {
                    $0.expiresAt.map { $0 > now } ?? true
                },
                metadata: license.metadata,
                product: license.product
            )
        } else {
            licenseResponse = LicenseResponse(
                object: "license",
                key: payload.licenseKey,
                status: "active",
                startsAt: nil,
                expiresAt: payload.licenseExpiresAt.map {
                    Date(timeIntervalSince1970: Double($0))
                },
                mode: "hardware_locked",
                planKey: "",
                seatLimit: nil,
                activeSeats: 0,
                activeEntitlements: [],
                metadata: payload.metadata.isEmpty ? nil : payload.metadata,
                product: Product(slug: payload.productSlug, name: payload.productSlug)
            )
        }

        return ValidationResponse(
            object: "validation_result",
            valid: true,
            code: nil,
            message: nil,
            warnings: nil,
            license: licenseResponse,
            activation: nil
        )
    }
}
