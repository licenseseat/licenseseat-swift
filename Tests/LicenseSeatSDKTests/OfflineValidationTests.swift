//
//  OfflineValidationTests.swift
//  LicenseSeatSDKTests
//
//  Created by LicenseSeat on 2025.
//

import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(CryptoKit)
import CryptoKit
#elseif canImport(Crypto)
import Crypto
#endif
@testable import LicenseSeat

@MainActor
final class OfflineValidationTests: LicenseSeatTestCase {
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
        _ = URLProtocol.registerClass(MockURLProtocol.self)
        MockURLProtocol.reset()
        // Hermetic by default: any request a test does not explicitly stub
        // behaves like a genuinely offline device instead of hitting live
        // DNS for the placeholder host.
        MockURLProtocol.requestHandler = { _ in
            throw URLError(.notConnectedToInternet)
        }

        let config = LicenseSeatConfig(
            apiBaseUrl: "https://api.test.com",
            productSlug: Self.testProductSlug,
            storagePrefix: "offline_validation_test_\(UUID().uuidString)_",
            maxRetries: 0,
            offlineFallbackMode: .always,
            maxOfflineDays: 7,
            maxClockSkewMs: 300000
        )
        sdk = LicenseSeat(config: config, urlSession: Self.makeMockedSession())
        sdk.cache.clear()
    }

    override func tearDown() {
        MainActor.assumeIsolated {
            sdk.reset()
            sdk = nil
            MockURLProtocol.reset()
            URLProtocol.unregisterClass(MockURLProtocol.self)
        }
        super.tearDown()
    }

    nonisolated private static func makeMockedSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: configuration)
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
        let tokenExp = exp ?? (now + 86400 * 30) // 30 days from now
        let tokenNbf = nbf ?? min(now, tokenExp)
        let issuedAt = iat ?? min(now, tokenNbf)

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

    private func sign(
        _ payload: OfflineTokenResponse.TokenPayload,
        with privateKey: Curve25519.Signing.PrivateKey
    ) throws -> OfflineTokenResponse {
        let encodedPayload = try JSONEncoder().encode(payload)
        let canonicalObject = try JSONSerialization.jsonObject(
            with: encodedPayload
        )
        let canonical = try CanonicalJSON.stringify(canonicalObject)
        let signature = try privateKey.signature(
            for: Data(canonical.utf8)
        )
        return OfflineTokenResponse(
            object: "offline_token",
            token: payload,
            signature: .init(
                algorithm: "Ed25519",
                keyId: payload.kid,
                value: Base64URL.encode(signature)
            ),
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
        XCTAssertTrue(
            sdk.cache.setPublicKey(
                "test-key-id",
                Base64URL.encode(publicKey.rawRepresentation)
            )
        )
        XCTAssertNotNil(sdk.cache.getPublicKey("test-key-id"))
        cacheTestLicense()

        // When
        let result = await sdk.verifyCachedOffline()

        // Then
        XCTAssertTrue(result.valid)
        XCTAssertNil(result.code)
    }

    func testLastSeenTimestampExposesTheProtectedWatermark() async throws {
        let privateKey = Curve25519.Signing.PrivateKey()
        let offlineToken = try makeOfflineToken(privateKey: privateKey)
        sdk.cache.setOfflineToken(offlineToken)
        XCTAssertTrue(
            sdk.cache.setPublicKey(
                "test-key-id",
                Base64URL.encode(privateKey.publicKey.rawRepresentation)
            )
        )
        cacheTestLicense()
        XCTAssertNil(sdk.lastSeenTimestamp())

        let before = Date()
        let result = await sdk.verifyCachedOffline()
        XCTAssertTrue(result.valid)

        let watermark = try XCTUnwrap(sdk.lastSeenTimestamp())
        XCTAssertEqual(
            watermark.timeIntervalSince1970,
            try XCTUnwrap(sdk.cache.getLastSeenTimestamp())
        )
        XCTAssertGreaterThanOrEqual(watermark, before.addingTimeInterval(-1))
        XCTAssertLessThanOrEqual(watermark, Date())
    }

    func testRubyGemSignedFixtureVerifiesInSwift() async throws {
        // This deterministic Ruby fixture deliberately includes Unicode,
        // escapes, slashes, nested arrays, Int64.max, negative zero, and
        // scientific/fractional numbers in metadata. Verification therefore
        // covers JSON decoding/re-encoding as well as Base64 and Ed25519.
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
            maxOfflineDays: 36_600
        )
        let crossLanguageSDK = LicenseSeat(config: config, urlSession: Self.makeMockedSession())
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

    func testTokenIsExpiredAtTheExactExpirationSecond() throws {
        let privateKey = Curve25519.Signing.PrivateKey()
        let now = 1_700_000_000
        let offlineToken = try makeOfflineToken(
            iat: now,
            exp: now,
            nbf: now,
            privateKey: privateKey
        )

        XCTAssertNoThrow(
            try sdk.validateOfflineTimeClaims(
                offlineToken.token,
                nowUnix: now - 1,
                clockSkewSeconds: 300
            )
        )
        XCTAssertThrowsError(
            try sdk.validateOfflineTimeClaims(
                offlineToken.token,
                nowUnix: now,
                clockSkewSeconds: 300
            )
        ) { error in
            XCTAssertEqual((error as? OfflineVerificationFailure)?.code, "token_expired")
        }
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

    func testLicenseIsExpiredAtTheExactExpirationSecond() throws {
        let privateKey = Curve25519.Signing.PrivateKey()
        let now = 1_700_000_000
        let offlineToken = try makeOfflineToken(
            iat: now - 60,
            exp: now + 60,
            nbf: now - 60,
            licenseExpiresAt: now,
            privateKey: privateKey
        )

        XCTAssertNoThrow(
            try sdk.validateOfflineTimeClaims(
                offlineToken.token,
                nowUnix: now - 1,
                clockSkewSeconds: 300
            )
        )
        XCTAssertThrowsError(
            try sdk.validateOfflineTimeClaims(
                offlineToken.token,
                nowUnix: now,
                clockSkewSeconds: 300
            )
        ) { error in
            XCTAssertEqual((error as? OfflineVerificationFailure)?.code, "license_expired")
        }
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

        // When: the signing-key fetch fails (mock transport is offline)
        let result = await sdk.verifyCachedOffline()

        // Then
        XCTAssertFalse(result.valid)
        XCTAssertEqual(result.code, "no_public_key")
    }

    func testMaxOfflineDaysZeroAppliesNoAdditionalHostAgeCap() async throws {
        // A grant issued long ago but still within its own signed `exp` must
        // authorize under the default policy: zero means "no host-side cap".
        let privateKey = Curve25519.Signing.PrivateKey()
        let now = Date()
        let token = try makeOfflineToken(
            iat: Int(now.addingTimeInterval(-400 * 86_400).timeIntervalSince1970),
            exp: Int(now.addingTimeInterval(30 * 86_400).timeIntervalSince1970),
            privateKey: privateKey
        )
        let defaultConfig = LicenseSeatConfig(
            apiBaseUrl: "https://api.test.com",
            productSlug: Self.testProductSlug,
            storagePrefix: "offline_default_\(UUID().uuidString)_",
            offlineFallbackMode: .always
        )
        XCTAssertEqual(defaultConfig.maxOfflineDays, 0)
        XCTAssertTrue(defaultConfig.offlineFallbackEnabled)

        let defaultSDK = LicenseSeat(
            config: defaultConfig,
            urlSession: Self.makeMockedSession()
        )
        defer { defaultSDK.reset() }
        await defaultSDK.waitForInitialization()
        XCTAssertTrue(defaultSDK.cache.setOfflineToken(token))
        XCTAssertTrue(defaultSDK.cache.setPublicKey(
            token.token.kid,
            Base64URL.encode(privateKey.publicKey.rawRepresentation)
        ))
        XCTAssertTrue(defaultSDK.cache.setLicense(License(
            licenseKey: token.token.licenseKey,
            deviceId: token.token.fingerprint,
            activationId: "default-offline-activation",
            activatedAt: Date(),
            lastValidated: Date()
        )))

        let result = await defaultSDK.verifyCachedOffline()

        XCTAssertTrue(result.valid)
        XCTAssertNil(result.code)
        XCTAssertTrue(
            defaultSDK.shouldFallbackToOffline(
                error: URLError(.notConnectedToInternet)
            )
        )
    }

    func testExpiredGrantStillFailsUnderTheDefaultOfflinePolicy() async throws {
        // The signed artifact's own expiry remains the governing deadline when
        // no host-side cap is configured.
        let privateKey = Curve25519.Signing.PrivateKey()
        let now = Date()
        let token = try makeOfflineToken(
            iat: Int(now.addingTimeInterval(-40 * 86_400).timeIntervalSince1970),
            exp: Int(now.addingTimeInterval(-86_400).timeIntervalSince1970),
            privateKey: privateKey
        )
        let defaultConfig = LicenseSeatConfig(
            apiBaseUrl: "https://api.test.com",
            productSlug: Self.testProductSlug,
            storagePrefix: "offline_default_expired_\(UUID().uuidString)_",
            offlineFallbackMode: .always
        )
        let defaultSDK = LicenseSeat(
            config: defaultConfig,
            urlSession: Self.makeMockedSession()
        )
        defer { defaultSDK.reset() }
        await defaultSDK.waitForInitialization()
        XCTAssertTrue(defaultSDK.cache.setOfflineToken(token))
        XCTAssertTrue(defaultSDK.cache.setPublicKey(
            token.token.kid,
            Base64URL.encode(privateKey.publicKey.rawRepresentation)
        ))
        XCTAssertTrue(defaultSDK.cache.setLicense(License(
            licenseKey: token.token.licenseKey,
            deviceId: token.token.fingerprint,
            activationId: "default-offline-expired-activation",
            activatedAt: Date(),
            lastValidated: Date()
        )))

        let result = await defaultSDK.verifyCachedOffline()

        XCTAssertFalse(result.valid)
        XCTAssertEqual(result.code, "token_expired")
    }

    func testDisabledOfflineFallbackDisablesAllOfflineAuthorityAndSync() async throws {
        let privateKey = Curve25519.Signing.PrivateKey()
        let token = try makeOfflineToken(privateKey: privateKey)
        let disabledConfig = LicenseSeatConfig(
            apiBaseUrl: "https://api.test.com",
            productSlug: Self.testProductSlug,
            storagePrefix: "offline_disabled_\(UUID().uuidString)_",
            offlineFallbackMode: .always,
            offlineFallbackEnabled: false
        )
        let disabledSDK = LicenseSeat(
            config: disabledConfig,
            urlSession: Self.makeMockedSession()
        )
        defer { disabledSDK.reset() }
        await disabledSDK.waitForInitialization()
        XCTAssertTrue(disabledSDK.cache.setOfflineToken(token))
        XCTAssertTrue(disabledSDK.cache.setPublicKey(
            token.token.kid,
            Base64URL.encode(privateKey.publicKey.rawRepresentation)
        ))
        XCTAssertTrue(disabledSDK.cache.setLicense(License(
            licenseKey: token.token.licenseKey,
            deviceId: token.token.fingerprint,
            activationId: "disabled-offline-activation",
            activatedAt: Date(),
            lastValidated: Date()
        )))
        var requests = 0
        MockURLProtocol.requestHandler = { _ in
            requests += 1
            throw URLError(.notConnectedToInternet)
        }

        let result = await disabledSDK.verifyCachedOffline()
        await disabledSDK.syncOfflineAssets()

        XCTAssertFalse(result.valid)
        XCTAssertEqual(result.code, "offline_disabled")
        XCTAssertFalse(
            disabledSDK.shouldFallbackToOffline(
                error: URLError(.notConnectedToInternet)
            )
        )
        XCTAssertEqual(requests, 0)
    }

    func testOutOfRangeOfflinePolicyFailsClosed() async throws {
        for days in [36_601, -1] {
            let config = LicenseSeatConfig(
                apiBaseUrl: "https://api.test.com",
                productSlug: Self.testProductSlug,
                storagePrefix: "offline_out_of_range_\(UUID().uuidString)_",
                maxOfflineDays: days
            )
            let invalidSDK = LicenseSeat(
                config: config,
                urlSession: Self.makeMockedSession()
            )
            defer { invalidSDK.reset() }

            let result = await invalidSDK.verifyCachedOffline()

            XCTAssertFalse(result.valid, "maxOfflineDays \(days) must fail closed")
            XCTAssertEqual(result.code, "invalid_configuration")
            XCTAssertFalse(
                invalidSDK.shouldFallbackToOffline(
                    error: URLError(.notConnectedToInternet)
                )
            )
        }
    }

    func testDuplicateEntitlementKeysCannotGrantAuthority() async throws {
        let privateKey = Curve25519.Signing.PrivateKey()
        let original = try makeOfflineToken(privateKey: privateKey)
        let payload = OfflineTokenResponse.TokenPayload(
            schemaVersion: original.token.schemaVersion,
            licenseKey: original.token.licenseKey,
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
            entitlements: [
                .init(key: "feature", expiresAt: nil),
                .init(key: "feature", expiresAt: nil)
            ],
            metadata: nil
        )
        let duplicated = try sign(payload, with: privateKey)
        XCTAssertTrue(sdk.cache.setOfflineToken(duplicated))
        XCTAssertTrue(sdk.cache.setPublicKey(
            payload.kid,
            Base64URL.encode(privateKey.publicKey.rawRepresentation)
        ))
        cacheTestLicense()

        let result = await sdk.verifyCachedOffline()

        XCTAssertFalse(result.valid)
        XCTAssertEqual(result.code, "invalid_token_claims")
    }

    func testDuplicateCanonicalMemberIsRejectedEvenWhenSigned() async throws {
        let privateKey = Curve25519.Signing.PrivateKey()
        let original = try makeOfflineToken(privateKey: privateKey)
        let duplicateCanonical = String(original.canonical.dropLast()) +
            #","kid":"test-key-id"}"#
        let signature = try privateKey.signature(
            for: Data(duplicateCanonical.utf8)
        )
        let ambiguous = OfflineTokenResponse(
            object: original.object,
            token: original.token,
            signature: .init(
                algorithm: "Ed25519",
                keyId: original.token.kid,
                value: Base64URL.encode(signature)
            ),
            canonical: duplicateCanonical
        )
        XCTAssertTrue(sdk.cache.setOfflineToken(ambiguous))
        XCTAssertTrue(sdk.cache.setPublicKey(
            original.token.kid,
            Base64URL.encode(privateKey.publicKey.rawRepresentation)
        ))
        cacheTestLicense()

        let result = await sdk.verifyCachedOffline()

        XCTAssertFalse(result.valid)
        XCTAssertEqual(result.code, "invalid_token_claims")
    }

    func testStructurallyUnboundedTokenLifetimeIsRejected() async throws {
        let privateKey = Curve25519.Signing.PrivateKey()
        let original = try makeOfflineToken(privateKey: privateKey)
        let payload = OfflineTokenResponse.TokenPayload(
            schemaVersion: original.token.schemaVersion,
            licenseKey: original.token.licenseKey,
            productSlug: original.token.productSlug,
            planKey: original.token.planKey,
            mode: original.token.mode,
            seatLimit: original.token.seatLimit,
            fingerprint: original.token.fingerprint,
            iat: original.token.iat,
            exp: original.token.iat + 101 * 366 * 86_400,
            nbf: original.token.iat,
            licenseExpiresAt: nil,
            kid: original.token.kid,
            entitlements: [],
            metadata: nil
        )
        let unbounded = try sign(payload, with: privateKey)
        XCTAssertTrue(sdk.cache.setOfflineToken(unbounded))
        XCTAssertTrue(sdk.cache.setPublicKey(
            payload.kid,
            Base64URL.encode(privateKey.publicKey.rawRepresentation)
        ))
        cacheTestLicense()

        let result = await sdk.verifyCachedOffline()

        XCTAssertFalse(result.valid)
        XCTAssertEqual(result.code, "invalid_token_claims")
    }

    func testExpiredOfflineEntitlementsAreNotProjectedAsActive() async throws {
        let privateKey = Curve25519.Signing.PrivateKey()
        let original = try makeOfflineToken(privateKey: privateKey)
        let now = Int(Date().timeIntervalSince1970)
        let payload = OfflineTokenResponse.TokenPayload(
            schemaVersion: original.token.schemaVersion,
            licenseKey: original.token.licenseKey,
            productSlug: original.token.productSlug,
            planKey: original.token.planKey,
            mode: original.token.mode,
            seatLimit: original.token.seatLimit,
            fingerprint: original.token.fingerprint,
            iat: original.token.iat,
            exp: original.token.exp,
            nbf: original.token.nbf,
            licenseExpiresAt: nil,
            kid: original.token.kid,
            entitlements: [
                .init(key: "expired", expiresAt: now - 1),
                .init(key: "current", expiresAt: now + 3_600)
            ],
            metadata: nil
        )
        let token = try sign(payload, with: privateKey)
        XCTAssertTrue(sdk.cache.setOfflineToken(token))
        XCTAssertTrue(sdk.cache.setPublicKey(
            payload.kid,
            Base64URL.encode(privateKey.publicKey.rawRepresentation)
        ))
        cacheTestLicense()

        let result = await sdk.verifyCachedOffline()

        XCTAssertTrue(result.valid)
        XCTAssertEqual(
            result.license.activeEntitlements.map(\.key),
            ["current"]
        )
    }

    func testAliasKeyedCanonicalIsRejectedAsPayloadMismatch() async throws {
        // The offline-token payload accepts only the canonical `fingerprint`
        // spelling. A producer that used a decode-only alias would carry a
        // VALID signature over its alias-keyed canonical, yet the verifier's
        // re-encoded payload emits `fingerprint` — so the equivalence check
        // must reject the token as token_payload_mismatch. This documents
        // that the aliases removed from TokenPayload never granted real
        // compatibility.
        let privateKey = Curve25519.Signing.PrivateKey()
        let signedToken = try makeOfflineToken(privateKey: privateKey)
        let aliasCanonical = signedToken.canonical.replacingOccurrences(
            of: "\"fingerprint\"",
            with: "\"device_id\""
        )
        XCTAssertNotEqual(aliasCanonical, signedToken.canonical)

        // Decoding the alias-keyed payload drops the device binding entirely.
        let aliasPayload = try JSONDecoder().decode(
            OfflineTokenResponse.TokenPayload.self,
            from: Data(aliasCanonical.utf8)
        )
        XCTAssertNil(aliasPayload.deviceId)

        let aliasSignature = try privateKey.signature(for: Data(aliasCanonical.utf8))
        let aliasToken = OfflineTokenResponse(
            object: "offline_token",
            token: aliasPayload,
            signature: .init(
                algorithm: "Ed25519",
                keyId: "test-key-id",
                value: Base64URL.encode(aliasSignature)
            ),
            canonical: aliasCanonical
        )

        sdk.cache.setOfflineToken(aliasToken)
        sdk.cache.setPublicKey(
            "test-key-id",
            Base64URL.encode(privateKey.publicKey.rawRepresentation)
        )
        cacheTestLicense()

        let result = await sdk.verifyCachedOffline()

        XCTAssertFalse(result.valid)
        XCTAssertEqual(result.code, "token_payload_mismatch")
    }

    func testAuthoritativeOnlineValidationRecoversPoisonedWatermark() async throws {
        // Given: a valid offline token, its signing key, and a cached license
        let privateKey = Curve25519.Signing.PrivateKey()
        let offlineToken = try makeOfflineToken(privateKey: privateKey)
        sdk.cache.setOfflineToken(offlineToken)
        sdk.cache.setPublicKey(
            "test-key-id",
            Base64URL.encode(privateKey.publicKey.rawRepresentation)
        )
        cacheTestLicense()

        // And: a watermark poisoned by a transiently future-set clock
        let poisoned = Date().addingTimeInterval(3_600).timeIntervalSince1970
        sdk.cache.setLastSeenTimestamp(poisoned)

        let poisonedResult = await sdk.verifyCachedOffline()
        XCTAssertFalse(poisonedResult.valid)
        XCTAssertEqual(poisonedResult.code, "clock_tamper")

        // When: the server accepts an authenticated validation request
        let validationBody = try JSONSerialization.data(withJSONObject: [
            "object": "validation_result",
            "valid": true,
            "code": NSNull(),
            "message": NSNull(),
            "warnings": NSNull(),
            "license": [
                "object": "license",
                "key": Self.testLicenseKey,
                "status": "active",
                "starts_at": NSNull(),
                "expires_at": NSNull(),
                "mode": "hardware_locked",
                "plan_key": "pro",
                "seat_limit": 5,
                "active_seats": 1,
                "active_entitlements": [],
                "metadata": NSNull(),
                "product": ["slug": Self.testProductSlug, "name": "Test App"]
            ],
            "activation": NSNull()
        ] as [String: Any])
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, validationBody)
        }

        let onlineResult = try await sdk.validate(licenseKey: Self.testLicenseKey)
        XCTAssertTrue(onlineResult.valid)

        // Then: the authoritative success re-anchored (lowered) the watermark
        let anchored = try XCTUnwrap(sdk.cache.getLastSeenTimestamp())
        XCTAssertLessThan(anchored, poisoned)
        XCTAssertEqual(anchored, Date().timeIntervalSince1970, accuracy: 30)

        // And: offline validation of the still-valid token works again
        let recovered = await sdk.verifyCachedOffline()
        XCTAssertTrue(recovered.valid)
        XCTAssertNil(recovered.code)

        // And: the offline ratchet still refuses to move backward
        let current = try XCTUnwrap(sdk.cache.getLastSeenTimestamp())
        sdk.cache.setLastSeenTimestamp(current - 3_000)
        XCTAssertEqual(
            try XCTUnwrap(sdk.cache.getLastSeenTimestamp()),
            current,
            accuracy: 0.001
        )
    }
}
