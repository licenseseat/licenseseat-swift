//
//  LicenseSeat+OfflineTokenVerification.swift
//  LicenseSeatSDK
//
//  Structural, cryptographic, identity, and time validation for signed grants.
//

import Foundation
#if canImport(CryptoKit)
import CryptoKit
#elseif canImport(Crypto)
import Crypto
#endif

extension LicenseSeat {
    func validateOfflineEnvelope(_ offlineToken: OfflineTokenResponse) throws {
        guard offlineToken.object == "offline_token" else {
            throw OfflineVerificationFailure(code: "invalid_token_object")
        }
        try validateOfflineSignatureMetadata(offlineToken)

        let canonicalMatches: Bool
        do {
            canonicalMatches = try canonicalPayloadMatchesToken(offlineToken)
        } catch {
            throw OfflineVerificationFailure(code: "invalid_token_claims")
        }
        guard canonicalMatches else {
            throw OfflineVerificationFailure(code: "token_payload_mismatch")
        }
        guard offlineToken.token.schemaVersion == 1 else {
            throw OfflineVerificationFailure(code: "unsupported_schema")
        }
        try validateOfflineClaimStructure(offlineToken)
    }

    private func validateOfflineSignatureMetadata(
        _ offlineToken: OfflineTokenResponse
    ) throws {
        guard offlineToken.signature.algorithm == "Ed25519",
              Self.validOfflineKeyId(offlineToken.token.kid),
              constantTimeEqual(
                  offlineToken.signature.keyId,
                  offlineToken.token.kid
              ) else {
            throw OfflineVerificationFailure(code: "signature_metadata_mismatch")
        }
    }

    private func validateOfflineClaimStructure(
        _ offlineToken: OfflineTokenResponse
    ) throws {
        let token = offlineToken.token
        guard !token.fingerprint.isEmpty else {
            throw OfflineVerificationFailure(code: "fingerprint_missing")
        }
        guard token.iat <= token.nbf, token.nbf <= token.exp else {
            throw OfflineVerificationFailure(code: "invalid_time_window")
        }
        let (lifetime, lifetimeOverflowed) = token.exp
            .subtractingReportingOverflow(token.iat)
        guard Self.safeOfflineText(token.licenseKey, maximumBytes: 512),
              token.productSlug.utf8.count <= 100,
              token.productSlug.range(
                  of: "^[a-z0-9]+(?:-[a-z0-9]+)*$",
                  options: .regularExpression
              ) != nil,
              Self.safeOfflineText(token.planKey, maximumBytes: 255),
              ["hardware_locked", "floating", "named_user"].contains(token.mode),
              Self.safeOfflineText(token.fingerprint, maximumBytes: 255),
              !lifetimeOverflowed,
              lifetime >= 0,
              lifetime <= Self.maxOfflineTokenLifetime,
              token.seatLimit == nil || token.seatLimit! > 0,
              token.entitlements.count <= Self.maxOfflineEntitlements,
              offlineToken.canonical.utf8.count <= Self.maxOfflineTokenBytes,
              offlineToken.signature.value.utf8.count <= 128 else {
            throw OfflineVerificationFailure(code: "invalid_token_claims")
        }
        try validateOfflineEntitlements(token.entitlements)
        try validateOfflineMetadata(token.metadata)
    }

    private func validateOfflineEntitlements(
        _ entitlements: [OfflineTokenResponse.TokenEntitlement]
    ) throws {
        var entitlementKeys = Set<String>()
        for entitlement in entitlements {
            guard entitlement.key.range(
                of: "^[a-z0-9][a-z0-9_-]{0,99}$",
                options: .regularExpression
            ) != nil,
            entitlementKeys.insert(entitlement.key).inserted else {
                throw OfflineVerificationFailure(code: "invalid_token_claims")
            }
        }
    }

    private func validateOfflineMetadata(
        _ metadata: [String: AnyCodable]?
    ) throws {
        guard let metadata else { return }
        guard let encoded = try? JSONEncoder().encode(metadata),
              encoded.count <= Self.maxOfflineTokenBytes,
              (try? StrictJSON.validate(encoded, limits: .signedPayload)) != nil else {
            throw OfflineVerificationFailure(code: "invalid_token_claims")
        }
    }

    func validateOfflineIdentity(_ offlineToken: OfflineTokenResponse) throws {
        guard let cachedLicense = cache.getLicense(),
              constantTimeEqual(offlineToken.token.licenseKey, cachedLicense.licenseKey) else {
            throw OfflineVerificationFailure(code: "license_mismatch")
        }
        if let configuredProduct = config.productSlug,
           !constantTimeEqual(offlineToken.token.productSlug, configuredProduct) {
            throw OfflineVerificationFailure(code: "product_mismatch")
        }
        guard constantTimeEqual(
            offlineToken.token.fingerprint,
            cachedLicense.deviceId
        ) else {
            throw OfflineVerificationFailure(code: "fingerprint_mismatch")
        }
    }

    func offlineClockSkewSeconds(nowUnix: Int) -> Int {
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

    func validateMaximumOfflineAge(
        issuedAt: Int,
        nowUnix: Int,
        clockSkewSeconds: Int
    ) throws {
        guard config.offlineAuthorityEnabled else {
            throw OfflineVerificationFailure(code: "offline_disabled")
        }

        let (offlineAge, ageOverflow) = nowUnix.subtractingReportingOverflow(issuedAt)
        guard !ageOverflow, offlineAge >= -clockSkewSeconds else {
            throw OfflineVerificationFailure(code: "clock_tamper")
        }
        // Zero means "no additional host-side age cap". The signed `exp`,
        // license expiry, and rollback watermark validated alongside this check
        // remain the governing deadlines.
        guard config.maxOfflineDays > 0 else { return }

        let (configuredGrace, graceOverflow) = config.maxOfflineDays
            .multipliedReportingOverflow(by: 86_400)
        let maximumOfflineSeconds = graceOverflow ? Int.max : configuredGrace
        guard offlineAge <= maximumOfflineSeconds else {
            throw OfflineVerificationFailure(code: "grace_period_expired")
        }
    }

    func persistOfflineClockState(now: Date, clockSkewSeconds: Int) throws {
        if let lastSeen = cache.getLastSeenTimestamp(),
           now.timeIntervalSince1970 + Double(clockSkewSeconds) < lastSeen {
            throw OfflineVerificationFailure(code: "clock_tamper")
        }
        guard cache.setLastSeenTimestamp(now.timeIntervalSince1970) else {
            throw OfflineVerificationFailure(code: "cache_error")
        }
    }

    private func canonicalPayloadMatchesToken(
        _ offlineToken: OfflineTokenResponse
    ) throws -> Bool {
        let canonicalData = Data(offlineToken.canonical.utf8)
        try StrictJSON.validate(canonicalData, limits: .signedPayload)
        let signedObject = try JSONSerialization.jsonObject(with: canonicalData)
        let encodedToken = try JSONEncoder().encode(offlineToken.token)
        try StrictJSON.validate(encodedToken, limits: .signedPayload)
        let tokenObject = try JSONSerialization.jsonObject(with: encodedToken)
        return constantTimeEqual(
            try CanonicalJSON.stringify(signedObject),
            try CanonicalJSON.stringify(tokenObject)
        )
    }

    func verifyOfflineToken(
        _ offlineToken: OfflineTokenResponse,
        publicKeyB64: String
    ) async throws -> Bool {
        log("Attempting to verify offline token client-side.")

        #if canImport(CryptoKit) || canImport(Crypto)
        let messageData = Data(offlineToken.canonical.utf8)
        let publicKeyData = try Base64URL.decode(publicKeyB64)
        guard publicKeyData.count == 32 else {
            throw LicenseSeatError.invalidPublicKey
        }
        let publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: publicKeyData)

        let signatureData = try Base64URL.decode(offlineToken.signature.value)
        guard signatureData.count == 64 else {
            throw LicenseSeatError.invalidOfflineToken
        }
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
        log("Offline verification crypto is unavailable")
        eventBus.emit("sdk:error", [
            "message": "Client-side verification crypto not available"
        ])
        throw LicenseSeatError.cryptoUnavailable
        #endif
    }

    func constantTimeEqual(_ first: String, _ second: String) -> Bool {
        Self.constantTimeEqual(first, second)
    }

    // MARK: - Shared Offline Predicates
    //
    // These three primitives are shared by the offline-token and machine-file
    // verifiers, and are `nonisolated` so response decoding can use them off
    // the main actor. One definition means one place to harden.

    nonisolated static func constantTimeEqual(_ first: String, _ second: String) -> Bool {
        let left = Array(first.utf8)
        let right = Array(second.utf8)
        var result = left.count ^ right.count
        for index in 0..<max(left.count, right.count) {
            let leftByte = index < left.count ? left[index] : 0
            let rightByte = index < right.count ? right[index] : 0
            result |= Int(leftByte ^ rightByte)
        }
        return result == 0
    }

    nonisolated static func validOfflineKeyId(_ value: String) -> Bool {
        value.utf8.count <= 255 &&
            value.range(
                of: "^[A-Za-z0-9][A-Za-z0-9._:-]*$",
                options: .regularExpression
            ) != nil
    }

    nonisolated static func safeOfflineText(
        _ value: String,
        minimumBytes: Int = 1,
        maximumBytes: Int
    ) -> Bool {
        value.utf8.count >= minimumBytes &&
            value.utf8.count <= maximumBytes &&
            value.unicodeScalars.allSatisfy {
                $0.value > 31 && $0.value != 127
            }
    }
}
