//
//  LicenseSeat+OfflineValidation.swift
//  LicenseSeatSDK
//
//  Created by LicenseSeat on 2025.
//  Copyright © 2025 LicenseSeat. All rights reserved.
//

import Foundation
// Prefer system CryptoKit; fallback to SwiftCrypto on platforms where it is unavailable (e.g. Linux)
#if canImport(CryptoKit)
import CryptoKit
#elseif canImport(Crypto)
import Crypto
#endif

struct OfflineVerificationFailure: Error {
    let code: String
}

struct OfflineSigningKeyVerification {
    let result: ValidationResponse
    let publicKey: String
    let fetched: Bool
}

extension LicenseSeat {
    static let maxOfflineTokenBytes = 1_048_576
    static let maxOfflineTokenLifetime = 100 * 366 * 86_400
    static let maxOfflineEntitlements = 500

    /// Verify the cached offline artifact and return a validation result.
    /// Use this to validate the license when the device is offline.
    ///
    /// The cached machine file is tried first. When it is absent or does not
    /// verify, and ``LicenseSeatConfig/legacyOfflineTokensEnabled`` is `true`,
    /// the cached legacy offline token is tried next. Artifacts are downloaded
    /// by `syncOfflineAssets()`. With nothing cached the result is invalid
    /// with code `no_offline_token`.
    public func verifyCachedOffline() async -> ValidationResponse {
        guard config.offlineFallbackEnabled else {
            return makeOfflineValidationResponse(
                valid: false,
                code: "offline_disabled"
            )
        }
        guard config.offlineAuthorityEnabled else {
            return makeOfflineValidationResponse(
                valid: false,
                code: "invalid_configuration"
            )
        }
        var machineFileFailure: ValidationResponse?
        if let machineFile = cache.getMachineFile() {
            let result = await verifyCachedMachineFileForAuthorization(
                machineFile,
                allowNetwork: true
            )
            if let result, result.valid { return result }
            if let code = result?.code, Self.definitiveMachineFileVerdicts.contains(code) {
                return result ?? makeOfflineValidationResponse(valid: false, code: code)
            }
            machineFileFailure = result
        }
        guard config.legacyOfflineTokensEnabled,
              let offlineToken = cache.getOfflineToken() else {
            return machineFileFailure
                ?? makeOfflineValidationResponse(valid: false, code: "no_offline_token")
        }

        do {
            let verification = try await verifyOfflineTokenWithSigningKeyRecovery(offlineToken)
            if verification.result.valid,
               verification.fetched,
               !cache.setPublicKey(offlineToken.token.kid, verification.publicKey) {
                return makeOfflineValidationResponse(valid: false, code: "cache_error")
            }
            return verification.result
        } catch let failure as OfflineVerificationFailure {
            return makeOfflineValidationResponse(
                valid: false,
                code: failure.code
            )
        } catch {
            return makeOfflineValidationResponse(valid: false, code: "no_public_key")
        }
    }

    /// Quick local offline verification (no network calls). Machine file
    /// first, then the legacy token when enabled; `nil` when no artifact gave
    /// a verdict that can be reached without the network. A machine file that
    /// could not vouch either way (for example a rotated signing key) is
    /// treated like an absent one at launch, so it never flashes an offline
    /// denial before online validation runs.
    func quickVerifyCachedOfflineLocal() async -> ValidationResponse? {
        guard config.offlineAuthorityEnabled else { return nil }

        if let machineFile = cache.getMachineFile(),
           let result = await verifyCachedMachineFileForAuthorization(
               machineFile,
               allowNetwork: false
           ) {
            if result.valid { return result }
            if let code = result.code, Self.definitiveMachineFileVerdicts.contains(code) {
                return result
            }
        }

        guard config.legacyOfflineTokensEnabled,
              let offlineToken = cache.getOfflineToken(),
              let publicKey = cache.getPublicKey(offlineToken.token.kid) else {
            return nil
        }

        return await verifyOfflineTokenAndClaims(offlineToken, publicKeyB64: publicKey)
    }

    /// Verifies an offline token with the protected cached signing key when it
    /// is structurally valid. A malformed key, or a syntactically valid key
    /// that fails the signature, is refreshed from the authoritative endpoint
    /// exactly once. This recovers isolated Keychain corruption without ever
    /// persisting an unverified replacement key or weakening any token claim.
    func verifyOfflineTokenWithSigningKeyRecovery(
        _ offlineToken: OfflineTokenResponse
    ) async throws -> OfflineSigningKeyVerification {
        guard config.offlineAuthorityEnabled else {
            throw OfflineVerificationFailure(code: "offline_disabled")
        }
        try validateOfflineEnvelope(offlineToken)
        let keyId = offlineToken.token.kid
        let cachedPublicKey = cache.getPublicKey(keyId)
        var fetched = false
        var publicKey: String

        if let cachedPublicKey, isValidEd25519PublicKey(cachedPublicKey) {
            publicKey = cachedPublicKey
        } else {
            publicKey = try await getSigningKey(keyId: keyId)
            fetched = true
        }

        var result = await verifyOfflineTokenAndClaims(
            offlineToken,
            publicKeyB64: publicKey
        )
        if !result.valid, result.code == "signature_invalid", !fetched {
            publicKey = try await getSigningKey(keyId: keyId)
            fetched = true
            result = await verifyOfflineTokenAndClaims(
                offlineToken,
                publicKeyB64: publicKey
            )
        }

        return OfflineSigningKeyVerification(
            result: result,
            publicKey: publicKey,
            fetched: fetched
        )
    }

    /// Verify the signature and every security-relevant claim. Both foreground
    /// fallback and launch-time "quick" validation use this single path so a
    /// cached token can never bypass device, product, expiry, grace, or clock
    /// rollback enforcement.
    func verifyOfflineTokenAndClaims(
        _ offlineToken: OfflineTokenResponse,
        publicKeyB64: String
    ) async -> ValidationResponse {
        do {
            guard config.offlineAuthorityEnabled,
                  config.maxClockSkewMs.isFinite,
                  config.maxClockSkewMs >= 0,
                  config.maxClockSkewMs <= 86_400_000 else {
                throw OfflineVerificationFailure(
                    code: "invalid_configuration"
                )
            }
            try validateOfflineEnvelope(offlineToken)
            guard try await verifyOfflineToken(offlineToken, publicKeyB64: publicKeyB64) else {
                throw OfflineVerificationFailure(code: "signature_invalid")
            }
            try validateOfflineIdentity(offlineToken)
            let instant = authorizationSnapshot()
            let nowUnix = Int(instant.effective.timeIntervalSince1970)
            let clockSkewSeconds = offlineClockSkewSeconds(nowUnix: nowUnix)
            try validateOfflineTimeClaims(
                offlineToken.token,
                nowUnix: nowUnix,
                clockSkewSeconds: clockSkewSeconds
            )
            try validateMaximumOfflineAge(
                issuedAt: offlineToken.token.iat,
                nowUnix: nowUnix,
                clockSkewSeconds: clockSkewSeconds
            )
            try persistOfflineClockState(instant, clockSkewSeconds: clockSkewSeconds)
            return makeOfflineValidationResponse(valid: true, code: nil, token: offlineToken)
        } catch let failure as OfflineVerificationFailure {
            return makeOfflineValidationResponse(valid: false, code: failure.code)
        } catch {
            return makeOfflineValidationResponse(valid: false, code: "verification_error")
        }
    }

    // MARK: - Helper Methods

    /// Build a ValidationResponse for offline validation
    func makeOfflineValidationResponse(
        valid: Bool,
        code: String?,
        token: OfflineTokenResponse? = nil
    ) -> ValidationResponse {
        // Create a minimal license response from the token if available
        let licenseResponse: LicenseResponse
        let entitlements: [Entitlement]

        if let token = token {
            // Convert token entitlements to regular entitlements
            let nowUnix = Int(authorizationTime().timeIntervalSince1970)
            entitlements = token.token.entitlements.compactMap { tokenEnt in
                guard tokenEnt.expiresAt == nil ||
                        tokenEnt.expiresAt! > nowUnix else {
                    return nil
                }
                let expiresAt: Date? = tokenEnt.expiresAt.map { Date(timeIntervalSince1970: Double($0)) }
                return Entitlement(key: tokenEnt.key, expiresAt: expiresAt, metadata: nil)
            }

            // Build license response from token data
            licenseResponse = LicenseResponse(
                object: "license",
                key: token.token.licenseKey,
                status: valid ? "active" : "invalid",
                startsAt: nil,
                expiresAt: token.token.licenseExpiresAt.map { Date(timeIntervalSince1970: Double($0)) },
                mode: token.token.mode,
                planKey: token.token.planKey,
                seatLimit: token.token.seatLimit,
                activeSeats: 0,
                activeEntitlements: entitlements,
                metadata: token.token.metadata,
                product: Product(slug: token.token.productSlug, name: token.token.productSlug)
            )
        } else {
            // Preserve the cached identity for error cases where no token was
            // available. Status correlation must never fall back to an empty
            // license key and accidentally leave the old grant looking active.
            let cachedLicense = cache.getLicense()
            entitlements = []
            licenseResponse = LicenseResponse(
                object: "license",
                key: cachedLicense?.licenseKey ?? "",
                status: "unknown",
                startsAt: nil,
                expiresAt: nil,
                mode: "unknown",
                planKey: "",
                seatLimit: nil,
                activeSeats: 0,
                activeEntitlements: [],
                metadata: nil,
                product: Product(
                    slug: config.productSlug ?? "",
                    name: config.productSlug ?? ""
                )
            )
        }

        return ValidationResponse(
            object: "validation_result",
            valid: valid,
            code: code,
            message: code.map { "Offline validation: \($0)" },
            warnings: nil,
            license: licenseResponse,
            activation: nil
        )
    }
}
