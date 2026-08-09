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
    var sdk: LicenseSeat!

    private static let testPrefix = "offline_validation_test_"
    private static let testProductSlug = "test-app"
    private static let testLicenseKey = "TEST-LICENSE-KEY"

    private struct CrossLanguageFixture: Decodable {
        let publicKey: String
        let offlineToken: OfflineTokenResponse

        enum CodingKeys: String, CodingKey {
            case publicKey = "public_key"
            case offlineToken = "offline_token"
        }
    }

    override func setUp() {
        super.setUp()
        let config = LicenseSeatConfig(
            apiBaseUrl: "https://api.test.com",
            productSlug: Self.testProductSlug,
            storagePrefix: "\(Self.testPrefix)\(UUID().uuidString)_",
            offlineFallbackMode: .always,
            maxOfflineDays: 7,
            maxClockSkewMs: 300000
        )
        sdk = LicenseSeat(config: config)
        sdk.cache.clear()
    }

    override func tearDown() {
        sdk.cache.clear()
        super.tearDown()
    }

    /// Helper to create an offline token with given parameters and sign it
    private func makeOfflineToken(
        licenseKey: String = "TEST-LICENSE-KEY",
        productSlug: String = "test-app",
        fingerprint: String = "test-device",
        exp: Int? = nil,
        nbf: Int? = nil,
        licenseExpiresAt: Int? = nil,
        privateKey: Curve25519.Signing.PrivateKey
    ) throws -> OfflineTokenResponse {
        let now = Int(Date().timeIntervalSince1970)
        let tokenExp = exp ?? (now + 86400 * 30) // 30 days from now
        let tokenNbf = nbf ?? min(now, tokenExp - 1)
        let tokenIat = min(now, tokenNbf)
        let kid = "test-key-id"

        let tokenPayload = OfflineTokenResponse.TokenPayload(
            schemaVersion: 1,
            licenseKey: licenseKey,
            productSlug: productSlug,
            planKey: "pro",
            mode: "hardware_locked",
            seatLimit: 5,
            fingerprint: fingerprint,
            iat: tokenIat,
            exp: tokenExp,
            nbf: tokenNbf,
            licenseExpiresAt: licenseExpiresAt,
            kid: kid,
            entitlements: [],
            metadata: nil
        )

        // Create canonical JSON for signing (simplified version for testing)
        let canonicalDict: [String: Any] = [
            "schema_version": 1,
            "license_key": licenseKey,
            "product_slug": productSlug,
            "plan_key": "pro",
            "mode": "hardware_locked",
            "seat_limit": 5,
            "fingerprint": fingerprint,
            "iat": tokenIat,
            "exp": tokenExp,
            "nbf": tokenNbf,
            "kid": kid,
            "entitlements": []
        ]
        let canonical = try CanonicalJSON.stringify(canonicalDict)

        // Sign the canonical JSON
        let signature = try privateKey.signature(for: Data(canonical.utf8))

        let signatureBlock = OfflineTokenResponse.Signature(
            algorithm: "Ed25519",
            keyId: kid,
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
    private func cacheTestLicense(licenseKey: String = "TEST-LICENSE-KEY", lastValidated: Date = Date()) {
        let license = License(
            licenseKey: licenseKey,
            deviceId: "test-device",
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

    func testRubySignedCrossLanguageFixtureVerifies() async throws {
        let fixtureURL = try XCTUnwrap(Bundle.module.url(
            forResource: "ruby_signed_offline_token",
            withExtension: "json",
            subdirectory: "Fixtures"
        ))
        let fixture = try JSONDecoder().decode(
            CrossLanguageFixture.self,
            from: Data(contentsOf: fixtureURL)
        )
        let config = LicenseSeatConfig(
            apiBaseUrl: "https://api.test.com",
            productSlug: fixture.offlineToken.token.productSlug,
            storagePrefix: "cross_language_fixture_",
            offlineFallbackMode: .always,
            maxOfflineDays: 36_600
        )
        let fixtureSDK = LicenseSeat(config: config)
        fixtureSDK.cache.clear()
        defer { fixtureSDK.cache.clear() }

        fixtureSDK.cache.setOfflineToken(fixture.offlineToken)
        fixtureSDK.cache.setPublicKey(fixture.offlineToken.token.kid, fixture.publicKey)
        fixtureSDK.cache.setLicense(License(
            licenseKey: fixture.offlineToken.token.licenseKey,
            deviceId: fixture.offlineToken.token.fingerprint,
            activationId: "cross-language-activation",
            activatedAt: Date(),
            lastValidated: Date()
        ))

        let result = await fixtureSDK.verifyCachedOffline()

        XCTAssertTrue(result.valid, result.code ?? "cross-language fixture was rejected")
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

    func testGracePeriodExpiry() async throws {
        // Given: A license validated more than maxOfflineDays ago
        let privateKey = Curve25519.Signing.PrivateKey()
        let publicKey = privateKey.publicKey

        let offlineToken = try makeOfflineToken(privateKey: privateKey)

        sdk.cache.setOfflineToken(offlineToken)
        sdk.cache.setPublicKey("test-key-id", Base64URL.encode(publicKey.rawRepresentation))

        // License last validated 8 days ago (exceeds 7 day grace period)
        cacheTestLicense(lastValidated: Date().addingTimeInterval(-8 * 86400))

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

    func testNoOfflineToken() async {
        // Given: No offline token cached
        cacheTestLicense()

        // When
        let result = await sdk.verifyCachedOffline()

        // Then
        XCTAssertFalse(result.valid)
        XCTAssertEqual(result.code, "no_offline_token")
    }

    func testMaxOfflineDaysZeroDisablesOfflineAuthority() async throws {
        let privateKey = Curve25519.Signing.PrivateKey()
        let offlineToken = try makeOfflineToken(privateKey: privateKey)
        let disabledConfig = LicenseSeatConfig(
            apiBaseUrl: "https://api.test.com",
            productSlug: Self.testProductSlug,
            storagePrefix: "offline_disabled_test_",
            offlineFallbackMode: .always,
            maxOfflineDays: 0
        )
        let disabledSDK = LicenseSeat(config: disabledConfig)
        disabledSDK.cache.clear()
        defer { disabledSDK.cache.clear() }
        disabledSDK.cache.setOfflineToken(offlineToken)
        disabledSDK.cache.setPublicKey(
            offlineToken.token.kid,
            Base64URL.encode(privateKey.publicKey.rawRepresentation)
        )
        disabledSDK.cache.setLicense(License(
            licenseKey: offlineToken.token.licenseKey,
            deviceId: offlineToken.token.fingerprint,
            activationId: "disabled-offline-activation",
            activatedAt: Date(),
            lastValidated: Date()
        ))

        let result = await disabledSDK.verifyCachedOffline()

        XCTAssertFalse(result.valid)
        XCTAssertEqual(result.code, "offline_disabled")
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

    func testDecodedClaimsMustMatchSignedCanonicalPayload() async throws {
        let privateKey = Curve25519.Signing.PrivateKey()
        let original = try makeOfflineToken(privateKey: privateKey)
        let payload = OfflineTokenResponse.TokenPayload(
            schemaVersion: original.token.schemaVersion,
            licenseKey: "ATTACKER-SELECTED-LICENSE",
            productSlug: original.token.productSlug,
            planKey: original.token.planKey,
            mode: original.token.mode,
            seatLimit: original.token.seatLimit,
            fingerprint: original.token.fingerprint,
            iat: original.token.iat,
            exp: original.token.exp,
            nbf: original.token.nbf,
            licenseExpiresAt: original.token.licenseExpiresAt,
            kid: original.token.kid,
            entitlements: original.token.entitlements,
            metadata: original.token.metadata
        )
        let tampered = OfflineTokenResponse(
            object: original.object,
            token: payload,
            signature: original.signature,
            canonical: original.canonical
        )

        sdk.cache.setOfflineToken(tampered)
        sdk.cache.setPublicKey(original.token.kid, Base64URL.encode(privateKey.publicKey.rawRepresentation))
        cacheTestLicense(licenseKey: payload.licenseKey)

        let result = await sdk.verifyCachedOffline()

        XCTAssertFalse(result.valid)
        XCTAssertEqual(result.code, "invalid_offline_token")
    }

    func testQuickStartupVerificationEnforcesExpiry() async throws {
        let privateKey = Curve25519.Signing.PrivateKey()
        let now = Int(Date().timeIntervalSince1970)
        let token = try makeOfflineToken(exp: now - 60, privateKey: privateKey)
        sdk.cache.setOfflineToken(token)
        sdk.cache.setPublicKey(token.token.kid, Base64URL.encode(privateKey.publicKey.rawRepresentation))
        cacheTestLicense()

        let result = await sdk.quickVerifyCachedOfflineLocal()

        XCTAssertEqual(result?.valid, false)
        XCTAssertEqual(result?.code, "token_expired")
    }

    func testOfflineTokenMustBeBoundToCachedDevice() async throws {
        let privateKey = Curve25519.Signing.PrivateKey()
        let token = try makeOfflineToken(fingerprint: "different-device", privateKey: privateKey)
        sdk.cache.setOfflineToken(token)
        sdk.cache.setPublicKey(token.token.kid, Base64URL.encode(privateKey.publicKey.rawRepresentation))
        cacheTestLicense()

        let result = await sdk.verifyCachedOffline()

        XCTAssertFalse(result.valid)
        XCTAssertEqual(result.code, "license_mismatch")
    }

    func testOfflineTokenRejectsAlgorithmConfusion() async throws {
        let privateKey = Curve25519.Signing.PrivateKey()
        let original = try makeOfflineToken(privateKey: privateKey)
        let tampered = OfflineTokenResponse(
            object: original.object,
            token: original.token,
            signature: .init(
                algorithm: "none",
                keyId: original.signature.keyId,
                value: original.signature.value
            ),
            canonical: original.canonical
        )
        sdk.cache.setOfflineToken(tampered)
        sdk.cache.setPublicKey(original.token.kid, Base64URL.encode(privateKey.publicKey.rawRepresentation))
        cacheTestLicense()

        let result = await sdk.verifyCachedOffline()

        XCTAssertFalse(result.valid)
        XCTAssertEqual(result.code, "invalid_offline_token")
    }
}
