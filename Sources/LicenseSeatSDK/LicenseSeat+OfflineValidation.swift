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

    private static let maxOfflineTokenBytes = 1_048_576
    private static let maxOfflineTokenLifetime = 100 * 366 * 24 * 60 * 60
    private static let maxOfflineEntitlements = 500

    /// Verify the cached offline token and return a validation result.
    /// Use this to validate the license when the device is offline.
    /// The offline token must have been previously downloaded via `syncOfflineAssets()`.
    public func verifyCachedOffline() async -> ValidationResponse {
        guard config.maxOfflineDays != 0 else {
            return makeOfflineValidationResponse(valid: false, code: "offline_disabled")
        }
        guard (1...36_600).contains(config.maxOfflineDays) else {
            return makeOfflineValidationResponse(valid: false, code: "invalid_configuration")
        }
        guard let offlineToken = cache.getOfflineToken() else {
            return makeOfflineValidationResponse(valid: false, code: "no_offline_token")
        }

        let kid = offlineToken.token.kid
        guard validOfflineKeyId(kid),
              constantTimeEqual(kid, offlineToken.signature.keyId) else {
            return makeOfflineValidationResponse(valid: false, code: "invalid_offline_token")
        }
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

        return await evaluateOfflineToken(offlineToken, publicKeyB64: publicKeyB64)
    }

    /// Quick local offline verification (no network calls)
    func quickVerifyCachedOfflineLocal() async -> ValidationResponse? {
        guard (1...36_600).contains(config.maxOfflineDays) else { return nil }
        guard let offlineToken = cache.getOfflineToken() else { return nil }

        let kid = offlineToken.token.kid
        guard validOfflineKeyId(kid),
              constantTimeEqual(kid, offlineToken.signature.keyId) else {
            return makeOfflineValidationResponse(valid: false, code: "invalid_offline_token")
        }
        guard let publicKey = cache.getPublicKey(kid) else { return nil }

        return await evaluateOfflineToken(offlineToken, publicKeyB64: publicKey)
    }

    func evaluateOfflineToken(
        _ offlineToken: OfflineTokenResponse,
        publicKeyB64: String
    ) async -> ValidationResponse {
        guard (1...36_600).contains(config.maxOfflineDays) else {
            return makeOfflineValidationResponse(valid: false, code: "invalid_configuration")
        }
        do {
            try validateOfflineTokenStructure(offlineToken)
            guard try await verifyOfflineToken(offlineToken, publicKeyB64: publicKeyB64) else {
                return makeOfflineValidationResponse(valid: false, code: "signature_invalid")
            }

            guard let cachedLicense = cache.getLicense(),
                  constantTimeEqual(offlineToken.token.licenseKey, cachedLicense.licenseKey),
                  constantTimeEqual(offlineToken.token.fingerprint, cachedLicense.deviceId),
                  let configuredProduct = config.productSlug,
                  constantTimeEqual(offlineToken.token.productSlug, configuredProduct) else {
                return makeOfflineValidationResponse(valid: false, code: "license_mismatch")
            }

            let now = Date()
            let nowUnix = Int(now.timeIntervalSince1970)
            if nowUnix >= offlineToken.token.exp {
                return makeOfflineValidationResponse(valid: false, code: "token_expired")
            }
            if nowUnix < offlineToken.token.nbf {
                return makeOfflineValidationResponse(valid: false, code: "token_not_yet_valid")
            }
            if let licenseExpiresAt = offlineToken.token.licenseExpiresAt,
               nowUnix >= licenseExpiresAt {
                return makeOfflineValidationResponse(valid: false, code: "license_expired")
            }

            guard config.maxClockSkewMs.isFinite, config.maxClockSkewMs >= 0 else {
                return makeOfflineValidationResponse(valid: false, code: "invalid_configuration")
            }
            let allowedClockSkew = config.maxClockSkewMs / 1_000
            if cachedLicense.lastValidated.timeIntervalSince1970 > now.timeIntervalSince1970 + allowedClockSkew {
                return makeOfflineValidationResponse(valid: false, code: "clock_tamper")
            }
            if let lastSeen = cache.getLastSeenTimestamp(),
               now.timeIntervalSince1970 + allowedClockSkew < lastSeen {
                return makeOfflineValidationResponse(valid: false, code: "clock_tamper")
            }

            let maximumAge = TimeInterval(config.maxOfflineDays) * 86_400
            if now.timeIntervalSince(cachedLicense.lastValidated) > maximumAge {
                return makeOfflineValidationResponse(valid: false, code: "grace_period_expired")
            }

            cache.setLastSeenTimestamp(now.timeIntervalSince1970)
            return makeOfflineValidationResponse(valid: true, code: nil, token: offlineToken)
        } catch {
            return makeOfflineValidationResponse(valid: false, code: "invalid_offline_token")
        }
    }

    private func validateOfflineTokenStructure(_ offlineToken: OfflineTokenResponse) throws {
        let token = offlineToken.token
        let (tokenLifetime, tokenLifetimeOverflowed) = token.exp.subtractingReportingOverflow(token.iat)
        guard offlineToken.object == "offline_token",
              offlineToken.signature.algorithm == "Ed25519",
              validOfflineKeyId(token.kid),
              constantTimeEqual(token.kid, offlineToken.signature.keyId),
              token.schemaVersion == 1,
              safeOfflineText(token.licenseKey, maximumBytes: 512),
              safeOfflineText(token.productSlug, maximumBytes: 255),
              safeOfflineText(token.planKey, maximumBytes: 255),
              ["hardware_locked", "floating", "named_user"].contains(token.mode),
              token.fingerprint.utf8.count >= 8,
              safeOfflineText(token.fingerprint, maximumBytes: 255),
              token.iat <= token.nbf,
              token.nbf <= token.exp,
              !tokenLifetimeOverflowed,
              tokenLifetime <= Self.maxOfflineTokenLifetime,
              token.seatLimit == nil || token.seatLimit! > 0,
              token.entitlements.count <= Self.maxOfflineEntitlements else {
            throw LicenseSeatError.invalidOfflineToken
        }

        var entitlementKeys = Set<String>()
        for entitlement in token.entitlements {
            guard entitlement.key.range(of: "^[a-z0-9][a-z0-9_-]{0,99}$", options: .regularExpression) != nil,
                  entitlementKeys.insert(entitlement.key).inserted else {
                throw LicenseSeatError.invalidOfflineToken
            }
        }

        guard offlineToken.canonical.utf8.count <= Self.maxOfflineTokenBytes,
              offlineToken.signature.value.utf8.count <= 128 else {
            throw LicenseSeatError.invalidOfflineToken
        }

        let signedPayload = try JSONDecoder().decode(
            StrictJSONValue.self,
            from: Data(offlineToken.canonical.utf8)
        )
        let decodedPayloadData = try JSONEncoder().encode(token)
        let decodedPayload = try JSONDecoder().decode(StrictJSONValue.self, from: decodedPayloadData)
        guard signedPayload == decodedPayload else {
            throw LicenseSeatError.invalidOfflineToken
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
        guard publicKeyData.count == 32 else { throw LicenseSeatError.invalidPublicKey }
        let publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: publicKeyData)

        // Decode signature (Base64URL encoded)
        let signatureData = try Base64URL.decode(offlineToken.signature.value)
        guard signatureData.count == 64 else { throw LicenseSeatError.invalidOfflineToken }

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
        let lhs = Array(a.utf8)
        let rhs = Array(b.utf8)
        guard lhs.count == rhs.count else { return false }

        var result: UInt8 = 0
        for (byteA, byteB) in zip(lhs, rhs) {
            result |= byteA ^ byteB
        }

        return result == 0
    }

    private func validOfflineKeyId(_ value: String) -> Bool {
        value.utf8.count <= 255 &&
            value.range(of: "^[A-Za-z0-9][A-Za-z0-9._:-]*$", options: .regularExpression) != nil
    }

    private func safeOfflineText(_ value: String, maximumBytes: Int) -> Bool {
        !value.isEmpty && value.utf8.count <= maximumBytes &&
            value.unicodeScalars.allSatisfy { $0.value > 31 && $0.value != 127 }
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
            let nowUnix = Int(Date().timeIntervalSince1970)
            entitlements = token.token.entitlements.compactMap { tokenEnt in
                guard tokenEnt.expiresAt == nil || tokenEnt.expiresAt! > nowUnix else { return nil }
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

/// A strict JSON value used to bind the separately decoded token object to the
/// exact payload represented by the signed `canonical` field. Unlike
/// Foundation's NSObject equality, this preserves boolean-versus-number type
/// distinctions.
private indirect enum StrictJSONValue: Decodable, Equatable {
    case null
    case boolean(Bool)
    case integer(Int64)
    case number(Double)
    case string(String)
    case array([StrictJSONValue])
    case object([String: StrictJSONValue])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .boolean(value)
        } else if let value = try? container.decode(Int64.self) {
            self = .integer(value)
        } else if let value = try? container.decode(Double.self), value.isFinite {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([StrictJSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: StrictJSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported JSON value"
            )
        }
    }
}
