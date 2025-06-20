//
//  EntitlementTests.swift
//  LicenseSeatSDKTests
//
//  Created by LicenseSeat on 2025.
//

import XCTest
@testable import LicenseSeatSDK

@MainActor
final class EntitlementTests: XCTestCase {
    var sdk: LicenseSeat?
    var cache: LicenseCache?
    
    override func setUp() {
        super.setUp()
        let config = LicenseSeatConfig(storagePrefix: "test_")
        sdk = LicenseSeat(config: config)
        cache = LicenseCache(prefix: "test_")
    }
    
    override func tearDown() {
        cache?.clear()
        super.tearDown()
    }
    
    func testActiveEntitlement() {
        // Given: A license with active entitlements
        let entitlement = Entitlement(
            key: "premium-features",
            name: "Premium Features",
            description: "Access to all premium features",
            expiresAt: Date().addingTimeInterval(86400), // Tomorrow
            metadata: ["tier": AnyCodable("gold")]
        )
        
        let validation = LicenseValidationResult(
            valid: true,
            reason: nil,
            offline: false,
            reasonCode: nil,
            optimistic: false,
            activeEntitlements: [entitlement]
        )
        
        let license = License(
            licenseKey: "TEST-KEY",
            deviceIdentifier: "device-1",
            activation: ActivationResult(id: "act-1", activatedAt: Date()),
            activatedAt: Date(),
            lastValidated: Date(),
            validation: validation
        )
        
        cache?.setLicense(license)
        
        // When
        guard let sdk = sdk else {
            XCTFail("SDK not initialized")
            return
        }
        let status = sdk.checkEntitlement("premium-features")
        
        // Then
        XCTAssertTrue(status.active)
        XCTAssertNil(status.reason)
        XCTAssertNotNil(status.entitlement)
        XCTAssertEqual(status.entitlement?.key, "premium-features")
    }
    
    func testExpiredEntitlement() {
        // Given: An expired entitlement
        let entitlement = Entitlement(
            key: "trial-access",
            name: "Trial Access",
            description: nil,
            expiresAt: Date().addingTimeInterval(-86400), // Yesterday
            metadata: nil
        )
        
        let validation = LicenseValidationResult(
            valid: true,
            reason: nil,
            offline: false,
            activeEntitlements: [entitlement]
        )
        
        let license = License(
            licenseKey: "TEST-KEY",
            deviceIdentifier: "device-1",
            activation: ActivationResult(id: "act-1", activatedAt: Date()),
            activatedAt: Date(),
            lastValidated: Date(),
            validation: validation
        )
        
        cache?.setLicense(license)
        
        // When
        guard let sdk = sdk else {
            XCTFail("SDK not initialized")
            return
        }
        let status = sdk.checkEntitlement("trial-access")
        
        // Then
        XCTAssertFalse(status.active)
        XCTAssertEqual(status.reason, .expired)
        XCTAssertNotNil(status.expiresAt)
    }
    
    func testMissingEntitlement() {
        // Given: A license without the requested entitlement
        let entitlement = Entitlement(
            key: "basic-features",
            name: "Basic Features",
            description: nil,
            expiresAt: nil,
            metadata: nil
        )
        
        let validation = LicenseValidationResult(
            valid: true,
            reason: nil,
            offline: false,
            activeEntitlements: [entitlement]
        )
        
        let license = License(
            licenseKey: "TEST-KEY",
            deviceIdentifier: "device-1",
            activation: ActivationResult(id: "act-1", activatedAt: Date()),
            activatedAt: Date(),
            lastValidated: Date(),
            validation: validation
        )
        
        cache?.setLicense(license)
        
        // When
        guard let sdk = sdk else {
            XCTFail("SDK not initialized")
            return
        }
        let status = sdk.checkEntitlement("premium-features")
        
        // Then
        XCTAssertFalse(status.active)
        XCTAssertEqual(status.reason, .notFound)
        XCTAssertNil(status.entitlement)
    }
    
    func testNoLicense() {
        // Given: No cached license
        
        // When
        guard let sdk = sdk else {
            XCTFail("SDK not initialized")
            return
        }
        let status = sdk.checkEntitlement("any-feature")
        
        // Then
        XCTAssertFalse(status.active)
        XCTAssertEqual(status.reason, .noLicense)
        XCTAssertNil(status.entitlement)
    }
    
    func testPermanentEntitlement() {
        // Given: An entitlement with no expiration
        let entitlement = Entitlement(
            key: "lifetime-access",
            name: "Lifetime Access",
            description: "Never expires",
            expiresAt: nil,
            metadata: nil
        )
        
        let validation = LicenseValidationResult(
            valid: true,
            reason: nil,
            offline: false,
            activeEntitlements: [entitlement]
        )
        
        let license = License(
            licenseKey: "TEST-KEY",
            deviceIdentifier: "device-1",
            activation: ActivationResult(id: "act-1", activatedAt: Date()),
            activatedAt: Date(),
            lastValidated: Date(),
            validation: validation
        )
        
        cache?.setLicense(license)
        
        // When
        guard let sdk = sdk else {
            XCTFail("SDK not initialized")
            return
        }
        let status = sdk.checkEntitlement("lifetime-access")
        
        // Then
        XCTAssertTrue(status.active)
        XCTAssertNil(status.reason)
        XCTAssertNil(status.expiresAt)
    }
} 