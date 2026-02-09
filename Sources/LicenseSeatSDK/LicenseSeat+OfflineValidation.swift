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

extension LicenseSeat {

    /// Verify the cached offline token and return a validation result.
    /// Use this to validate the license when the device is offline.
    /// The offline token must have been previously downloaded via `syncOfflineAssets()`.
    public func verifyCachedOffline() async -> ValidationResponse {
        guard let offlineToken = cache.getOfflineToken() else {
            return makeOfflineValidationResponse(valid: false, code: "no_offline_token")
        }

        let kid = offlineToken.token.kid
        var publicKey = cache.getPublicKey(kid)

        // Try to fetch public key if not cached
        if publicKey == nil {
            do {
                publicKey = try await getSigningKey(keyId: kid)
                cache.setPublicKey(kid, publicKey!)
            } catch {
                return makeOfflineValidationResponse(valid: false, code: "no_public_key")
            }
        }

        guard let publicKeyB64 = publicKey else {
            return makeOfflineValidationResponse(valid: false, code: "no_public_key")
        }

        do {
            let isValid = try await verifyOfflineToken(
                offlineToken,
                publicKeyB64: publicKeyB64
            )

            if !isValid {
                return makeOfflineValidationResponse(valid: false, code: "signature_invalid")
            }

            // Payload sanity checks
            guard let cachedLicense = cache.getLicense() else {
                return makeOfflineValidationResponse(valid: false, code: "license_mismatch")
            }

            // 1. License key match (constant-time comparison)
            if !constantTimeEqual(offlineToken.token.licenseKey, cachedLicense.licenseKey) {
                return makeOfflineValidationResponse(valid: false, code: "license_mismatch")
            }

            // 2. Check token expiry (exp is Unix timestamp)
            let now = Date()
            let nowUnix = Int(now.timeIntervalSince1970)

            if nowUnix > offlineToken.token.exp {
                return makeOfflineValidationResponse(valid: false, code: "token_expired")
            }

            // 3. Check not-before (nbf is Unix timestamp)
            if nowUnix < offlineToken.token.nbf {
                return makeOfflineValidationResponse(valid: false, code: "token_not_yet_valid")
            }

            // 4. Check license expiry if present
            if let licenseExpiresAt = offlineToken.token.licenseExpiresAt {
                if nowUnix > licenseExpiresAt {
                    return makeOfflineValidationResponse(valid: false, code: "license_expired")
                }
            }

            // 5. Grace period check
            if config.maxOfflineDays > 0 {
                let pivot = cachedLicense.lastValidated
                let ageInDays = Calendar.current.dateComponents(
                    [.day],
                    from: pivot,
                    to: now
                ).day ?? 0

                if ageInDays > config.maxOfflineDays {
                    return makeOfflineValidationResponse(valid: false, code: "grace_period_expired")
                }
            }

            // 6. Clock tamper detection
            if let lastSeenMs = cache.getLastSeenTimestamp() {
                let nowMs = now.timeIntervalSince1970
                if nowMs + (config.maxClockSkewMs / 1000) < lastSeenMs {
                    return makeOfflineValidationResponse(valid: false, code: "clock_tamper")
                }
            }

            // Update last seen timestamp
            cache.setLastSeenTimestamp(now.timeIntervalSince1970)

            // Build successful response with entitlements
            return makeOfflineValidationResponse(
                valid: true,
                code: nil,
                token: offlineToken
            )

        } catch {
            return makeOfflineValidationResponse(valid: false, code: "verification_error")
        }
    }

    /// Quick local offline verification (no network calls)
    func quickVerifyCachedOfflineLocal() async -> ValidationResponse? {
        guard let offlineToken = cache.getOfflineToken() else { return nil }

        let kid = offlineToken.token.kid
        guard let publicKey = cache.getPublicKey(kid) else { return nil }

        do {
            let isValid = try await verifyOfflineToken(
                offlineToken,
                publicKeyB64: publicKey
            )

            if isValid {
                return makeOfflineValidationResponse(valid: true, code: nil, token: offlineToken)
            } else {
                return makeOfflineValidationResponse(valid: false, code: "signature_invalid")
            }
        } catch {
            return makeOfflineValidationResponse(valid: false, code: "verification_error")
        }
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
        guard a.count == b.count else { return false }

        var result = 0
        for (charA, charB) in zip(a, b) {
            result |= Int(charA.asciiValue ?? 0) ^ Int(charB.asciiValue ?? 0)
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
            // Fallback for error cases where we don't have token data
            entitlements = []
            licenseResponse = LicenseResponse(
                object: "license",
                key: "",
                status: "unknown",
                startsAt: nil,
                expiresAt: nil,
                mode: "unknown",
                planKey: "",
                seatLimit: nil,
                activeSeats: 0,
                activeEntitlements: [],
                metadata: nil,
                product: Product(slug: "", name: "")
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
