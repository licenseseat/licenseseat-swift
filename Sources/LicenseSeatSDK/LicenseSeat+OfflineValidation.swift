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

    /// Verify the cached offline token and return a validation result.
    /// Use this to validate the license when the device is offline.
    /// The offline token must have been previously downloaded via `syncOfflineAssets()`.
    public func verifyCachedOffline() async -> ValidationResponse {
        guard let offlineToken = cache.getOfflineToken() else {
            return makeOfflineValidationResponse(valid: false, code: "no_offline_token")
        }

        do {
            let verification = try await verifyOfflineTokenWithSigningKeyRecovery(offlineToken)
            if verification.result.valid,
               verification.fetched,
               !cache.setPublicKey(offlineToken.token.kid, verification.publicKey) {
                return makeOfflineValidationResponse(valid: false, code: "cache_error")
            }
            return verification.result
        } catch {
            return makeOfflineValidationResponse(valid: false, code: "no_public_key")
        }
    }

    /// Quick local offline verification (no network calls)
    func quickVerifyCachedOfflineLocal() async -> ValidationResponse? {
        guard let offlineToken = cache.getOfflineToken() else { return nil }

        let kid = offlineToken.token.kid
        guard let publicKey = cache.getPublicKey(kid) else { return nil }

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
            try validateOfflineEnvelope(offlineToken)
            guard try await verifyOfflineToken(offlineToken, publicKeyB64: publicKeyB64) else {
                throw OfflineVerificationFailure(code: "signature_invalid")
            }
            try validateOfflineIdentity(offlineToken)
            let now = Date()
            let nowUnix = Int(now.timeIntervalSince1970)
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
            try persistOfflineClockState(now: now, clockSkewSeconds: clockSkewSeconds)
            return makeOfflineValidationResponse(valid: true, code: nil, token: offlineToken)
        } catch let failure as OfflineVerificationFailure {
            return makeOfflineValidationResponse(valid: false, code: failure.code)
        } catch {
            return makeOfflineValidationResponse(valid: false, code: "verification_error")
        }
    }

    private func validateOfflineEnvelope(_ offlineToken: OfflineTokenResponse) throws {
        guard offlineToken.object == "offline_token" else {
            throw OfflineVerificationFailure(code: "invalid_token_object")
        }
        guard offlineToken.signature.algorithm.caseInsensitiveCompare("Ed25519") == .orderedSame,
              constantTimeEqual(offlineToken.signature.keyId, offlineToken.token.kid) else {
            throw OfflineVerificationFailure(code: "signature_metadata_mismatch")
        }
        guard try canonicalPayloadMatchesToken(offlineToken) else {
            throw OfflineVerificationFailure(code: "token_payload_mismatch")
        }
        guard offlineToken.token.schemaVersion == 1 else {
            throw OfflineVerificationFailure(code: "unsupported_schema")
        }
        guard !offlineToken.token.licenseKey.isEmpty,
              !offlineToken.token.productSlug.isEmpty,
              !offlineToken.token.planKey.isEmpty,
              !offlineToken.token.mode.isEmpty,
              !offlineToken.token.kid.isEmpty,
              offlineToken.token.entitlements.allSatisfy({ !$0.key.isEmpty }) else {
            throw OfflineVerificationFailure(code: "invalid_token_claims")
        }
    }

    private func validateOfflineIdentity(_ offlineToken: OfflineTokenResponse) throws {
        guard let cachedLicense = cache.getLicense(),
              constantTimeEqual(offlineToken.token.licenseKey, cachedLicense.licenseKey) else {
            throw OfflineVerificationFailure(code: "license_mismatch")
        }
        if let configuredProduct = config.productSlug,
           !constantTimeEqual(offlineToken.token.productSlug, configuredProduct) {
            throw OfflineVerificationFailure(code: "product_mismatch")
        }
        guard let tokenFingerprint = offlineToken.token.deviceId else {
            throw OfflineVerificationFailure(code: "fingerprint_missing")
        }
        guard constantTimeEqual(tokenFingerprint, cachedLicense.deviceId) else {
            throw OfflineVerificationFailure(code: "fingerprint_mismatch")
        }
    }

    private func offlineClockSkewSeconds(nowUnix: Int) -> Int {
        let configuredClockSkew = config.maxClockSkewMs.isFinite
            ? max(0, config.maxClockSkewMs)
            : 0
        return Int(min(configuredClockSkew / 1_000, Double(Int.max - nowUnix)))
    }

    func validateOfflineTimeClaims(
        _ token: OfflineTokenResponse.TokenPayload,
        nowUnix: Int,
        clockSkewSeconds: Int
    ) throws {
        guard token.iat <= nowUnix + clockSkewSeconds else {
            throw OfflineVerificationFailure(code: "clock_tamper")
        }
        guard nowUnix < token.exp else {
            throw OfflineVerificationFailure(code: "token_expired")
        }
        guard token.iat <= token.nbf, token.nbf <= token.exp else {
            throw OfflineVerificationFailure(code: "invalid_time_window")
        }
        guard nowUnix + clockSkewSeconds >= token.nbf else {
            throw OfflineVerificationFailure(code: "token_not_yet_valid")
        }
        if let licenseExpiresAt = token.licenseExpiresAt, nowUnix >= licenseExpiresAt {
            throw OfflineVerificationFailure(code: "license_expired")
        }
    }

    private func validateMaximumOfflineAge(
        issuedAt: Int,
        nowUnix: Int,
        clockSkewSeconds: Int
    ) throws {
        guard config.maxOfflineDays > 0 else { return }

        // `iat` is covered by the Ed25519 signature. Unlike a locally mutable
        // validation timestamp it cannot create a sliding offline grace period.
        let (offlineAge, ageOverflow) = nowUnix.subtractingReportingOverflow(issuedAt)
        guard !ageOverflow, offlineAge >= -clockSkewSeconds else {
            throw OfflineVerificationFailure(code: "clock_tamper")
        }
        let (configuredGrace, graceOverflow) = config.maxOfflineDays
            .multipliedReportingOverflow(by: 86_400)
        let maximumOfflineSeconds = graceOverflow ? Int.max : configuredGrace
        guard offlineAge <= maximumOfflineSeconds else {
            throw OfflineVerificationFailure(code: "grace_period_expired")
        }
    }

    private func persistOfflineClockState(now: Date, clockSkewSeconds: Int) throws {
        if let lastSeen = cache.getLastSeenTimestamp(),
           now.timeIntervalSince1970 + Double(clockSkewSeconds) < lastSeen {
            throw OfflineVerificationFailure(code: "clock_tamper")
        }
        guard cache.setLastSeenTimestamp(now.timeIntervalSince1970) else {
            throw OfflineVerificationFailure(code: "cache_error")
        }
    }

    private func canonicalPayloadMatchesToken(_ offlineToken: OfflineTokenResponse) throws -> Bool {
        let signedObject = try JSONSerialization.jsonObject(with: Data(offlineToken.canonical.utf8))
        let encodedToken = try JSONEncoder().encode(offlineToken.token)
        let tokenObject = try JSONSerialization.jsonObject(with: encodedToken)
        return constantTimeEqual(
            try CanonicalJSON.stringify(signedObject),
            try CanonicalJSON.stringify(tokenObject)
        )
    }

    /// Verify offline token signature using the canonical JSON field
    private func verifyOfflineToken(
        _ offlineToken: OfflineTokenResponse,
        publicKeyB64: String
    ) async throws -> Bool {
        log("Attempting to verify offline token client-side.")

        #if canImport(CryptoKit) || canImport(Crypto)
        // The canonical field contains the exact string that was signed
        let messageData = Data(offlineToken.canonical.utf8)

        // Decode public key (Base64URL encoded)
        let publicKeyData = try Base64URL.decode(publicKeyB64)
        let publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: publicKeyData)

        // Decode signature (Base64URL encoded)
        let signatureData = try Base64URL.decode(offlineToken.signature.value)

        // Verify
        let isValid = publicKey.isValidSignature(signatureData, for: messageData)

        if isValid {
            log("Offline token signature VERIFIED successfully client-side.")
            eventBus.emit("offlineToken:verified", ["kid": offlineToken.token.kid])
        } else {
            log("Offline token signature INVALID client-side.")
            eventBus.emit("offlineToken:verificationFailed", ["kid": offlineToken.token.kid])
        }

        return isValid
        #else
        // CryptoKit not available - can't verify
        log("CryptoKit not available for offline verification")
        eventBus.emit("sdk:error", [
            "message": "Client-side verification crypto not available"
        ])
        throw LicenseSeatError.cryptoUnavailable
        #endif
    }

    /// Constant-time string comparison
    private func constantTimeEqual(_ a: String, _ b: String) -> Bool {
        let left = Array(a.utf8)
        let right = Array(b.utf8)
        guard left.count == right.count else { return false }

        var result = 0
        for (leftByte, rightByte) in zip(left, right) {
            result |= Int(leftByte ^ rightByte)
        }

        return result == 0
    }

    // MARK: - Helper Methods

    /// Build a ValidationResponse for offline validation
    private func makeOfflineValidationResponse(
        valid: Bool,
        code: String?,
        token: OfflineTokenResponse? = nil
    ) -> ValidationResponse {
        // Create a minimal license response from the token if available
        let licenseResponse: LicenseResponse
        let entitlements: [Entitlement]

        if let token = token {
            // Convert token entitlements to regular entitlements
            entitlements = token.token.entitlements.map { tokenEnt in
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
