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

    override func setUp() {
        super.setUp()
        let config = LicenseSeatConfig(
            apiBaseUrl: "https://api.test.com",
            productSlug: Self.testProductSlug,
            storagePrefix: Self.testPrefix,
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
        licenseKey: String = testLicenseKey,
        productSlug: String = testProductSlug,
        exp: Int? = nil,
        nbf: Int? = nil,
        licenseExpiresAt: Int? = nil,
        privateKey: Curve25519.Signing.PrivateKey
    ) throws -> OfflineTokenResponse {
        let now = Int(Date().timeIntervalSince1970)
        let tokenExp = exp ?? (now + 86400 * 30) // 30 days from now
        let tokenNbf = nbf ?? now
        let kid = "test-key-id"

        let tokenPayload = OfflineTokenResponse.TokenPayload(
            schemaVersion: 1,
            licenseKey: licenseKey,
            productSlug: productSlug,
            planKey: "pro",
            mode: "hardware_locked",
            seatLimit: 5,
            deviceId: "test-device",
            iat: now,
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
            "device_id": "test-device",
            "iat": now,
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
    private func cacheTestLicense(licenseKey: String = testLicenseKey, lastValidated: Date = Date()) {
        let license = License(
            licenseKey: licenseKey,
            deviceId: "test-device",
            activationId: 12345,
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
