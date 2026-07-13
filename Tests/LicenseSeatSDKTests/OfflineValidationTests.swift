//
//  OfflineValidationTests.swift
//  LicenseSeatSDKTests
//
//  Created by LicenseSeat on 2025.
//

import XCTest
#if canImport(CryptoKit)
import CryptoKit
#elseif canImport(Crypto)
import Crypto
#endif
@testable import LicenseSeat

@MainActor
final class OfflineValidationTests: XCTestCase {
    private struct CrossLanguageFixture: Decodable {
        let publicKey: String
        let offlineToken: OfflineTokenResponse

        enum CodingKeys: String, CodingKey {
            case publicKey = "public_key"
            case offlineToken = "offline_token"
        }
    }

    var sdk: LicenseSeat!

    nonisolated private static let testProductSlug = "test-app"
    nonisolated private static let testLicenseKey = "TEST-LICENSE-KEY"

    override func setUp() async throws {
        let config = LicenseSeatConfig(
            apiBaseUrl: "https://api.test.com",
            productSlug: Self.testProductSlug,
            storagePrefix: "offline_validation_test_\(UUID().uuidString)_",
            maxRetries: 0,
            offlineFallbackMode: .always,
            maxOfflineDays: 7,
            maxClockSkewMs: 300000
        )
        sdk = LicenseSeat(config: config)
        sdk.cache.clear()
    }

    override func tearDown() async throws {
        sdk.reset()
        sdk = nil
    }

    /// Helper to create an offline token with given parameters and sign it
    private func makeOfflineToken(
        licenseKey: String = testLicenseKey,
        productSlug: String = testProductSlug,
        schemaVersion: Int = 1,
        fingerprint: String? = "test-device",
        iat: Int? = nil,
        exp: Int? = nil,
        nbf: Int? = nil,
        licenseExpiresAt: Int? = nil,
        kid: String = "test-key-id",
        algorithm: String = "Ed25519",
        signatureKeyId: String? = nil,
        privateKey: Curve25519.Signing.PrivateKey
    ) throws -> OfflineTokenResponse {
        let now = Int(Date().timeIntervalSince1970)
        let issuedAt = iat ?? now
        let tokenExp = exp ?? (now + 86400 * 30) // 30 days from now
        let tokenNbf = nbf ?? now

        let tokenPayload = OfflineTokenResponse.TokenPayload(
            schemaVersion: schemaVersion,
            licenseKey: licenseKey,
            productSlug: productSlug,
            planKey: "pro",
            mode: "hardware_locked",
            seatLimit: 5,
            deviceId: fingerprint,
            iat: issuedAt,
            exp: tokenExp,
            nbf: tokenNbf,
            licenseExpiresAt: licenseExpiresAt,
            kid: kid,
            entitlements: [],
            metadata: nil
        )

        // Derive the signed representation from the exact Codable payload.
        // This keeps the fixture honest when optional claims are added.
        let encodedPayload = try JSONEncoder().encode(tokenPayload)
        let canonicalObject = try JSONSerialization.jsonObject(with: encodedPayload)
        let canonical = try CanonicalJSON.stringify(canonicalObject)

        // Sign the canonical JSON
        let signature = try privateKey.signature(for: Data(canonical.utf8))

        let signatureBlock = OfflineTokenResponse.Signature(
            algorithm: algorithm,
            keyId: signatureKeyId ?? kid,
            value: Base64URL.encode(signature)
        )

        return OfflineTokenResponse(
            object: "offline_token",
            token: tokenPayload,
            signature: signatureBlock,
            canonical: canonical
        )
    }

    /// Helper to create and cache a test license
    private func cacheTestLicense(
        licenseKey: String = testLicenseKey,
        fingerprint: String = "test-device",
        lastValidated: Date = Date()
    ) {
        let license = License(
            licenseKey: licenseKey,
            deviceId: fingerprint,
            activationId: "act-12345-uuid",
            activatedAt: Date(),
            lastValidated: lastValidated
        )
        sdk.cache.setLicense(license)
    }

    func testValidOfflineSignatureVerification() async throws {
        // Given: A valid Ed25519 signed offline token
        let privateKey = Curve25519.Signing.PrivateKey()
        let publicKey = privateKey.publicKey

        let offlineToken = try makeOfflineToken(privateKey: privateKey)

        // Cache the token and public key
        sdk.cache.setOfflineToken(offlineToken)
        sdk.cache.setPublicKey("test-key-id", Base64URL.encode(publicKey.rawRepresentation))
        cacheTestLicense()

        // When
        let result = await sdk.verifyCachedOffline()

        // Then
        XCTAssertTrue(result.valid)
        XCTAssertNil(result.code)
    }

    func testRubyGemSignedFixtureVerifiesInSwift() async throws {
        let fixtureURL = try XCTUnwrap(
            Bundle.module.url(
                forResource: "ruby_signed_offline_token",
                withExtension: "json"
            )
        )
        let fixture = try JSONDecoder().decode(
            CrossLanguageFixture.self,
            from: Data(contentsOf: fixtureURL)
        )
        let config = LicenseSeatConfig(
            productSlug: "hustl",
            storagePrefix: "cross_language_test_\(UUID().uuidString)_",
            deviceIdentifier: "test-device",
            offlineFallbackMode: .always,
            maxOfflineDays: 0
        )
        let crossLanguageSDK = LicenseSeat(config: config)
        defer { crossLanguageSDK.reset() }

        XCTAssertTrue(crossLanguageSDK.cache.setOfflineToken(fixture.offlineToken))
        XCTAssertTrue(
            crossLanguageSDK.cache.setPublicKey(
                "cross-language-2026",
                fixture.publicKey
            )
        )
        XCTAssertTrue(
            crossLanguageSDK.cache.setLicense(
                License(
                    licenseKey: "CROSS-LANGUAGE-LICENSE",
                    deviceId: "test-device",
                    activationId: "cross-language-activation",
                    activatedAt: Date(timeIntervalSince1970: 1_700_000_000),
                    lastValidated: Date(timeIntervalSince1970: 1_700_000_000)
                )
            )
        )

        let result = await crossLanguageSDK.verifyCachedOffline()

        XCTAssertTrue(result.valid)
        XCTAssertNil(result.code)
    }

    func testInvalidSignatureFails() async throws {
        // Given: A token with invalid signature
        let privateKey = Curve25519.Signing.PrivateKey()
        let publicKey = privateKey.publicKey

        var offlineToken = try makeOfflineToken(privateKey: privateKey)

        // Tamper with the signature
        let tamperedSignature = OfflineTokenResponse.Signature(
            algorithm: "Ed25519",
            keyId: "test-key-id",
            value: "invalid-signature-value"
        )
        offlineToken = OfflineTokenResponse(
            object: offlineToken.object,
            token: offlineToken.token,
            signature: tamperedSignature,
            canonical: offlineToken.canonical
        )

        sdk.cache.setOfflineToken(offlineToken)
        sdk.cache.setPublicKey("test-key-id", Base64URL.encode(publicKey.rawRepresentation))
        cacheTestLicense()

        // When
        let result = await sdk.verifyCachedOffline()

        // Then
        XCTAssertFalse(result.valid)
        // Either verification_error or signature_invalid
        XCTAssertNotNil(result.code)
    }

    func testExpiredTokenFails() async throws {
        // Given: An expired offline token
        let privateKey = Curve25519.Signing.PrivateKey()
        let publicKey = privateKey.publicKey

        let now = Int(Date().timeIntervalSince1970)
        let offlineToken = try makeOfflineToken(
            exp: now - 86400, // Expired yesterday
            privateKey: privateKey
        )

        sdk.cache.setOfflineToken(offlineToken)
        sdk.cache.setPublicKey("test-key-id", Base64URL.encode(publicKey.rawRepresentation))
        cacheTestLicense()

        // When
        let result = await sdk.verifyCachedOffline()

        // Then
        XCTAssertFalse(result.valid)
        XCTAssertEqual(result.code, "token_expired")
    }

    func testTokenNotYetValid() async throws {
        // Given: A token that's not yet valid (nbf in future)
        let privateKey = Curve25519.Signing.PrivateKey()
        let publicKey = privateKey.publicKey

        let now = Int(Date().timeIntervalSince1970)
        let offlineToken = try makeOfflineToken(
            nbf: now + 86400, // Valid starting tomorrow
            privateKey: privateKey
        )

        sdk.cache.setOfflineToken(offlineToken)
        sdk.cache.setPublicKey("test-key-id", Base64URL.encode(publicKey.rawRepresentation))
        cacheTestLicense()

        // When
        let result = await sdk.verifyCachedOffline()

        // Then
        XCTAssertFalse(result.valid)
        XCTAssertEqual(result.code, "token_not_yet_valid")
    }

    func testIssuedAtAfterNotBeforeIsRejected() async throws {
        let privateKey = Curve25519.Signing.PrivateKey()
        let now = Int(Date().timeIntervalSince1970)
        let offlineToken = try makeOfflineToken(
            iat: now,
            exp: now + 3_600,
            nbf: now - 1,
            privateKey: privateKey
        )
        sdk.cache.setOfflineToken(offlineToken)
        sdk.cache.setPublicKey(
            "test-key-id",
            Base64URL.encode(privateKey.publicKey.rawRepresentation)
        )
        cacheTestLicense()

        let result = await sdk.verifyCachedOffline()

        XCTAssertFalse(result.valid)
        XCTAssertEqual(result.code, "invalid_time_window")
    }

    func testUnexpectedOfflineTokenObjectIsRejected() async throws {
        let privateKey = Curve25519.Signing.PrivateKey()
        let signedToken = try makeOfflineToken(privateKey: privateKey)
        let offlineToken = OfflineTokenResponse(
            object: "not_an_offline_token",
            token: signedToken.token,
            signature: signedToken.signature,
            canonical: signedToken.canonical
        )
        sdk.cache.setOfflineToken(offlineToken)
        sdk.cache.setPublicKey(
            "test-key-id",
            Base64URL.encode(privateKey.publicKey.rawRepresentation)
        )
        cacheTestLicense()

        let result = await sdk.verifyCachedOffline()

        XCTAssertFalse(result.valid)
        XCTAssertEqual(result.code, "invalid_token_object")
    }

    func testGracePeriodExpiry() async throws {
        // Given: A signed token issued more than maxOfflineDays ago
        let privateKey = Curve25519.Signing.PrivateKey()
        let publicKey = privateKey.publicKey

        let offlineToken = try makeOfflineToken(
            iat: Int(Date().addingTimeInterval(-8 * 86400).timeIntervalSince1970),
            privateKey: privateKey
        )

        sdk.cache.setOfflineToken(offlineToken)
        sdk.cache.setPublicKey("test-key-id", Base64URL.encode(publicKey.rawRepresentation))

        cacheTestLicense()

        // When
        let result = await sdk.verifyCachedOffline()

        // Then
        XCTAssertFalse(result.valid)
        XCTAssertEqual(result.code, "grace_period_expired")
    }

    func testClockTamperDetection() async throws {
        // Given: Last seen timestamp is in the future (beyond allowed skew)
        sdk.cache.setLastSeenTimestamp(Date().addingTimeInterval(600).timeIntervalSince1970) // 10 minutes in future

        let privateKey = Curve25519.Signing.PrivateKey()
        let publicKey = privateKey.publicKey

        let offlineToken = try makeOfflineToken(privateKey: privateKey)

        sdk.cache.setOfflineToken(offlineToken)
        sdk.cache.setPublicKey("test-key-id", Base64URL.encode(publicKey.rawRepresentation))
        cacheTestLicense()

        // When
        let result = await sdk.verifyCachedOffline()

        // Then
        XCTAssertFalse(result.valid)
        XCTAssertEqual(result.code, "clock_tamper")
    }

    func testLicenseKeyMismatch() async throws {
        // Given: Offline token with different key than cached license
        let privateKey = Curve25519.Signing.PrivateKey()
        let publicKey = privateKey.publicKey

        let offlineToken = try makeOfflineToken(
            licenseKey: "DIFFERENT-LICENSE-KEY",
            privateKey: privateKey
        )

        sdk.cache.setOfflineToken(offlineToken)
        sdk.cache.setPublicKey("test-key-id", Base64URL.encode(publicKey.rawRepresentation))
        cacheTestLicense(licenseKey: Self.testLicenseKey) // Different key

        // When
        let result = await sdk.verifyCachedOffline()

        // Then
        XCTAssertFalse(result.valid)
        XCTAssertEqual(result.code, "license_mismatch")
    }

    func testProductMismatchFails() async throws {
        let privateKey = Curve25519.Signing.PrivateKey()
        let offlineToken = try makeOfflineToken(
            productSlug: "different-product",
            privateKey: privateKey
        )

        sdk.cache.setOfflineToken(offlineToken)
        sdk.cache.setPublicKey("test-key-id", Base64URL.encode(privateKey.publicKey.rawRepresentation))
        cacheTestLicense()

        let result = await sdk.verifyCachedOffline()

        XCTAssertFalse(result.valid)
        XCTAssertEqual(result.code, "product_mismatch")
    }

    func testMissingFingerprintFails() async throws {
        let privateKey = Curve25519.Signing.PrivateKey()
        let offlineToken = try makeOfflineToken(fingerprint: nil, privateKey: privateKey)

        sdk.cache.setOfflineToken(offlineToken)
        sdk.cache.setPublicKey("test-key-id", Base64URL.encode(privateKey.publicKey.rawRepresentation))
        cacheTestLicense()

        let result = await sdk.verifyCachedOffline()

        XCTAssertFalse(result.valid)
        XCTAssertEqual(result.code, "fingerprint_missing")
    }

    func testFingerprintMismatchFails() async throws {
        let privateKey = Curve25519.Signing.PrivateKey()
        let offlineToken = try makeOfflineToken(
            fingerprint: "different-device",
            privateKey: privateKey
        )

        sdk.cache.setOfflineToken(offlineToken)
        sdk.cache.setPublicKey("test-key-id", Base64URL.encode(privateKey.publicKey.rawRepresentation))
        cacheTestLicense()

        let result = await sdk.verifyCachedOffline()

        XCTAssertFalse(result.valid)
        XCTAssertEqual(result.code, "fingerprint_mismatch")
    }

    func testExpiredLicenseClaimFailsEvenWhenTokenIsCurrent() async throws {
        let privateKey = Curve25519.Signing.PrivateKey()
        let offlineToken = try makeOfflineToken(
            licenseExpiresAt: Int(Date().addingTimeInterval(-60).timeIntervalSince1970),
            privateKey: privateKey
        )

        sdk.cache.setOfflineToken(offlineToken)
        sdk.cache.setPublicKey("test-key-id", Base64URL.encode(privateKey.publicKey.rawRepresentation))
        cacheTestLicense()

        let result = await sdk.verifyCachedOffline()

        XCTAssertFalse(result.valid)
        XCTAssertEqual(result.code, "license_expired")
    }

    func testUnsupportedSchemaFails() async throws {
        let privateKey = Curve25519.Signing.PrivateKey()
        let offlineToken = try makeOfflineToken(schemaVersion: 2, privateKey: privateKey)

        sdk.cache.setOfflineToken(offlineToken)
        sdk.cache.setPublicKey("test-key-id", Base64URL.encode(privateKey.publicKey.rawRepresentation))
        cacheTestLicense()

        let result = await sdk.verifyCachedOffline()

        XCTAssertFalse(result.valid)
        XCTAssertEqual(result.code, "unsupported_schema")
    }

    func testUnsupportedSignatureAlgorithmFailsBeforeCryptoVerification() async throws {
        let privateKey = Curve25519.Signing.PrivateKey()
        let offlineToken = try makeOfflineToken(
            algorithm: "none",
            privateKey: privateKey
        )

        sdk.cache.setOfflineToken(offlineToken)
        sdk.cache.setPublicKey("test-key-id", Base64URL.encode(privateKey.publicKey.rawRepresentation))
        cacheTestLicense()

        let result = await sdk.verifyCachedOffline()

        XCTAssertFalse(result.valid)
        XCTAssertEqual(result.code, "signature_metadata_mismatch")
    }

    func testSignatureKeyIDMustMatchSignedTokenKeyID() async throws {
        let privateKey = Curve25519.Signing.PrivateKey()
        let offlineToken = try makeOfflineToken(
            signatureKeyId: "different-key-id",
            privateKey: privateKey
        )

        sdk.cache.setOfflineToken(offlineToken)
        sdk.cache.setPublicKey("test-key-id", Base64URL.encode(privateKey.publicKey.rawRepresentation))
        cacheTestLicense()

        let result = await sdk.verifyCachedOffline()

        XCTAssertFalse(result.valid)
        XCTAssertEqual(result.code, "signature_metadata_mismatch")
    }

    func testUnsignedSiblingTokenSubstitutionFails() async throws {
        let privateKey = Curve25519.Signing.PrivateKey()
        let signedToken = try makeOfflineToken(privateKey: privateKey)
        let attackerControlledToken = try makeOfflineToken(
            productSlug: "attacker-product",
            fingerprint: "attacker-device",
            exp: Int(Date().addingTimeInterval(365 * 86400).timeIntervalSince1970),
            privateKey: privateKey
        )
        let substitutedResponse = OfflineTokenResponse(
            object: signedToken.object,
            token: attackerControlledToken.token,
            signature: signedToken.signature,
            canonical: signedToken.canonical
        )

        sdk.cache.setOfflineToken(substitutedResponse)
        sdk.cache.setPublicKey("test-key-id", Base64URL.encode(privateKey.publicKey.rawRepresentation))
        cacheTestLicense()

        let result = await sdk.verifyCachedOffline()

        XCTAssertFalse(result.valid)
        XCTAssertEqual(result.code, "token_payload_mismatch")
    }

    func testQuickLocalVerificationEnforcesExpiredTokenClaim() async throws {
        let privateKey = Curve25519.Signing.PrivateKey()
        let offlineToken = try makeOfflineToken(
            exp: Int(Date().addingTimeInterval(-60).timeIntervalSince1970),
            privateKey: privateKey
        )

        sdk.cache.setOfflineToken(offlineToken)
        sdk.cache.setPublicKey("test-key-id", Base64URL.encode(privateKey.publicKey.rawRepresentation))
        cacheTestLicense()

        let result = await sdk.quickVerifyCachedOfflineLocal()

        XCTAssertEqual(result?.valid, false)
        XCTAssertEqual(result?.code, "token_expired")
    }

    func testNoOfflineToken() async {
        // Given: No offline token cached
        cacheTestLicense()

        // When
        let result = await sdk.verifyCachedOffline()

        // Then
        XCTAssertFalse(result.valid)
        XCTAssertEqual(result.code, "no_offline_token")
    }

    func testNoPublicKey() async throws {
        // Given: Offline token but no public key cached
        let privateKey = Curve25519.Signing.PrivateKey()

        let offlineToken = try makeOfflineToken(privateKey: privateKey)
        sdk.cache.setOfflineToken(offlineToken)
        // Don't cache public key
        cacheTestLicense()

        // When
        let result = await sdk.verifyCachedOffline()

        // Then
        XCTAssertFalse(result.valid)
        XCTAssertEqual(result.code, "no_public_key")
    }
}
