//
//  EntitlementTests.swift
//  LicenseSeatSDKTests
//
//  Created by LicenseSeat on 2025.
//

import XCTest
@testable import LicenseSeat

@MainActor
final class EntitlementTests: LicenseSeatTestCase {
    var sdk: LicenseSeat?

    private static let testProductSlug = "test-app"

    override func setUp() async throws {
        let config = LicenseSeatConfig(
            productSlug: Self.testProductSlug,
            storagePrefix: "entitlement_test_\(UUID().uuidString)_"
        )
        sdk = LicenseSeat(config: config)
        sdk?.cache.clear()
    }

    override func tearDown() {
        MainActor.assumeIsolated {
            sdk?.reset()
            sdk = nil
        }
        super.tearDown()
    }

    /// Helper to create a mock validation response with entitlements
    private func makeValidation(entitlements: [Entitlement]) -> ValidationResponse {
        let licenseResponse = LicenseResponse(
            object: "license",
            key: "TEST-KEY",
            status: "active",
            startsAt: nil,
            expiresAt: nil,
            mode: "hardware_locked",
            planKey: "pro",
            seatLimit: 5,
            activeSeats: 1,
            activeEntitlements: entitlements,
            metadata: nil,
            product: Product(slug: Self.testProductSlug, name: "Test App")
        )

        return ValidationResponse(
            object: "validation_result",
            valid: true,
            code: nil,
            message: nil,
            warnings: nil,
            license: licenseResponse,
            activation: nil
        )
    }

    /// Helper to create a cached license with validation
    private func makeLicense(validation: ValidationResponse) -> License {
        return License(
            licenseKey: "TEST-KEY",
            deviceId: "device-1",
            activationId: "act-12345-uuid",
            activatedAt: Date(),
            lastValidated: Date(),
            validation: validation
        )
    }

    func testActiveEntitlement() async {
        // Given: A license with active entitlements
        let entitlement = Entitlement(
            key: "premium-features",
            expiresAt: Date().addingTimeInterval(86400), // Tomorrow
            metadata: ["tier": AnyCodable("gold")]
        )

        let validation = makeValidation(entitlements: [entitlement])
        let license = makeLicense(validation: validation)
        sdk?.cache.setLicense(license)

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

    func testExpiredEntitlement() async {
        // Given: An expired entitlement
        let entitlement = Entitlement(
            key: "trial-access",
            expiresAt: Date().addingTimeInterval(-86400), // Yesterday
            metadata: nil
        )

        let validation = makeValidation(entitlements: [entitlement])
        let license = makeLicense(validation: validation)
        sdk?.cache.setLicense(license)

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

    func testMissingEntitlement() async {
        // Given: A license without the requested entitlement
        let entitlement = Entitlement(
            key: "basic-features",
            expiresAt: nil,
            metadata: nil
        )

        let validation = makeValidation(entitlements: [entitlement])
        let license = makeLicense(validation: validation)
        sdk?.cache.setLicense(license)

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

    func testNoLicense() async {
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

    func testPermanentEntitlement() async {
        // Given: An entitlement with no expiration
        let entitlement = Entitlement(
            key: "lifetime-access",
            expiresAt: nil,
            metadata: nil
        )

        let validation = makeValidation(entitlements: [entitlement])
        let license = makeLicense(validation: validation)
        sdk?.cache.setLicense(license)

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
