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
@testable import LicenseSeatSDK

@MainActor
final class OfflineValidationTests: XCTestCase {
    var sdk: LicenseSeat!
    var cache: LicenseCache!
    
    override func setUp() {
        super.setUp()
        let config = LicenseSeatConfig(
            apiBaseUrl: "https://api.test.com",
            storagePrefix: "test_",
            offlineFallbackEnabled: true,
            maxOfflineDays: 7,
            maxClockSkewMs: 300000
        )
        sdk = LicenseSeat(config: config)
        cache = LicenseCache(prefix: "test_")
    }
    
    override func tearDown() {
        cache.clear()
        super.tearDown()
    }
    
    func testValidOfflineSignatureVerification() async throws {
        // Given: A valid Ed25519 signed license
        let privateKey = Curve25519.Signing.PrivateKey()
        let publicKey = privateKey.publicKey
        
        let payload: [String: Any] = [
            "lic_k": "TEST-LICENSE-KEY",
            "exp_at": ISO8601DateFormatter().string(from: Date().addingTimeInterval(86400)),
            "kid": "test-key-id"
        ]
        
        let payloadString = try CanonicalJSON.stringify(payload)
        let signature = try privateKey.signature(for: Data(payloadString.utf8))
        
        let offlineLicense = OfflineLicense(
            payload: payload,
            signatureB64u: Base64URL.encode(signature),
            kid: "test-key-id"
        )
        
        // Cache the license and public key
        cache.setOfflineLicense(offlineLicense)
        cache.setPublicKey("test-key-id", Base64URL.encode(publicKey.rawRepresentation))
        
        let testLicense = License(
            licenseKey: "TEST-LICENSE-KEY",
            deviceIdentifier: "test-device",
            activation: ActivationResult(id: "test", activatedAt: Date()),
            activatedAt: Date(),
            lastValidated: Date()
        )
        cache.setLicense(testLicense)
        
        // When
        let result = await sdk.verifyCachedOffline()
        
        // Then
        XCTAssertTrue(result.valid)
        XCTAssertTrue(result.offline)
        XCTAssertNil(result.reasonCode)
    }
    
    func testInvalidSignatureFails() async throws {
        // Given: A license with tampered signature
        let payload: [String: Any] = [
            "lic_k": "TEST-LICENSE-KEY",
            "exp_at": ISO8601DateFormatter().string(from: Date().addingTimeInterval(86400))
        ]
        
        let offlineLicense = OfflineLicense(
            payload: payload,
            signatureB64u: "invalid-signature",
            kid: "test-key-id"
        )
        
        cache.setOfflineLicense(offlineLicense)
        cache.setPublicKey("test-key-id", "invalid-public-key")
        
        // When
        let result = await sdk.verifyCachedOffline()
        
        // Then
        XCTAssertFalse(result.valid)
        XCTAssertEqual(result.reasonCode, "verification_error")
    }
    
    func testExpiredLicenseFails() async throws {
        // Given: An expired offline license
        let privateKey = Curve25519.Signing.PrivateKey()
        let publicKey = privateKey.publicKey
        
        let payload: [String: Any] = [
            "lic_k": "TEST-LICENSE-KEY",
            "exp_at": ISO8601DateFormatter().string(from: Date().addingTimeInterval(-86400)), // Yesterday
            "kid": "test-key-id"
        ]
        
        let payloadString = try CanonicalJSON.stringify(payload)
        let signature = try privateKey.signature(for: Data(payloadString.utf8))
        
        let offlineLicense = OfflineLicense(
            payload: payload,
            signatureB64u: Base64URL.encode(signature),
            kid: "test-key-id"
        )
        
        cache.setOfflineLicense(offlineLicense)
        cache.setPublicKey("test-key-id", Base64URL.encode(publicKey.rawRepresentation))
        
        let testLicense = License(
            licenseKey: "TEST-LICENSE-KEY",
            deviceIdentifier: "test-device",
            activation: ActivationResult(id: "test", activatedAt: Date()),
            activatedAt: Date(),
            lastValidated: Date()
        )
        cache.setLicense(testLicense)
        
        // When
        let result = await sdk.verifyCachedOffline()
        
        // Then
        XCTAssertFalse(result.valid)
        XCTAssertEqual(result.reasonCode, "expired")
    }
    
    func testGracePeriodExpiry() async throws {
        // Given: A license validated more than maxOfflineDays ago
        let privateKey = Curve25519.Signing.PrivateKey()
        let publicKey = privateKey.publicKey
        
        let payload: [String: Any] = [
            "lic_k": "TEST-LICENSE-KEY",
            "kid": "test-key-id"
            // No exp_at, so grace period applies
        ]
        
        let payloadString = try CanonicalJSON.stringify(payload)
        let signature = try privateKey.signature(for: Data(payloadString.utf8))
        
        let offlineLicense = OfflineLicense(
            payload: payload,
            signatureB64u: Base64URL.encode(signature),
            kid: "test-key-id"
        )
        
        cache.setOfflineLicense(offlineLicense)
        cache.setPublicKey("test-key-id", Base64URL.encode(publicKey.rawRepresentation))
        
        // License last validated 8 days ago (exceeds 7 day grace period)
        let testLicense = License(
            licenseKey: "TEST-LICENSE-KEY",
            deviceIdentifier: "test-device",
            activation: ActivationResult(id: "test", activatedAt: Date()),
            activatedAt: Date().addingTimeInterval(-10 * 86400),
            lastValidated: Date().addingTimeInterval(-8 * 86400)
        )
        cache.setLicense(testLicense)
        
        // When
        let result = await sdk.verifyCachedOffline()
        
        // Then
        XCTAssertFalse(result.valid)
        XCTAssertEqual(result.reasonCode, "grace_period_expired")
    }
    
    func testClockTamperDetection() async throws {
        // Given: Last seen timestamp is in the future
        cache.setLastSeenTimestamp(Date().addingTimeInterval(600).timeIntervalSince1970) // 10 minutes in future
        
        let privateKey = Curve25519.Signing.PrivateKey()
        let publicKey = privateKey.publicKey
        
        let payload: [String: Any] = [
            "lic_k": "TEST-LICENSE-KEY",
            "kid": "test-key-id"
        ]
        
        let payloadString = try CanonicalJSON.stringify(payload)
        let signature = try privateKey.signature(for: Data(payloadString.utf8))
        
        let offlineLicense = OfflineLicense(
            payload: payload,
            signatureB64u: Base64URL.encode(signature),
            kid: "test-key-id"
        )
        
        cache.setOfflineLicense(offlineLicense)
        cache.setPublicKey("test-key-id", Base64URL.encode(publicKey.rawRepresentation))
        
        let testLicense = License(
            licenseKey: "TEST-LICENSE-KEY",
            deviceIdentifier: "test-device",
            activation: ActivationResult(id: "test", activatedAt: Date()),
            activatedAt: Date(),
            lastValidated: Date()
        )
        cache.setLicense(testLicense)
        
        // When
        let result = await sdk.verifyCachedOffline()
        
        // Then
        XCTAssertFalse(result.valid)
        XCTAssertEqual(result.reasonCode, "clock_tamper")
    }
    
    func testLicenseKeyMismatch() async throws {
        // Given: Offline license with different key than cached
        let privateKey = Curve25519.Signing.PrivateKey()
        let publicKey = privateKey.publicKey
        
        let payload: [String: Any] = [
            "lic_k": "DIFFERENT-LICENSE-KEY",
            "kid": "test-key-id"
        ]
        
        let payloadString = try CanonicalJSON.stringify(payload)
        let signature = try privateKey.signature(for: Data(payloadString.utf8))
        
        let offlineLicense = OfflineLicense(
            payload: payload,
            signatureB64u: Base64URL.encode(signature),
            kid: "test-key-id"
        )
        
        cache.setOfflineLicense(offlineLicense)
        cache.setPublicKey("test-key-id", Base64URL.encode(publicKey.rawRepresentation))
        
        let testLicense = License(
            licenseKey: "TEST-LICENSE-KEY",
            deviceIdentifier: "test-device",
            activation: ActivationResult(id: "test", activatedAt: Date()),
            activatedAt: Date(),
            lastValidated: Date()
        )
        cache.setLicense(testLicense)
        
        // When
        let result = await sdk.verifyCachedOffline()
        
        // Then
        XCTAssertFalse(result.valid)
        XCTAssertEqual(result.reasonCode, "license_mismatch")
    }
} 