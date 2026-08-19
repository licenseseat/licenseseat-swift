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

    // MARK: - Version ceilings (server API 2026-08-19)

    /// The server's `below_version` ceiling must decode, and its absence
    /// (every response from an older server) must decode as nil — the field
    /// is additive in both directions.
    func testBelowVersionDecodesAndOlderPayloadsStayNil() throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let bounded = """
        {"key": "updates", "expires_at": null, "below_version": "3.0.0", "metadata": {}}
        """.data(using: .utf8)!
        let entitlement = try decoder.decode(Entitlement.self, from: bounded)
        XCTAssertEqual(entitlement.belowVersion, "3.0.0")

        let legacy = """
        {"key": "updates", "expires_at": null, "metadata": {}}
        """.data(using: .utf8)!
        XCTAssertNil(try decoder.decode(Entitlement.self, from: legacy).belowVersion)
    }

    /// A version-gated validation refusal is a normal `valid: false` envelope
    /// with the `version_not_entitled` code — it must decode like any other
    /// invalid result, code and message intact, entitlements included.
    func testVersionNotEntitledValidationResponseDecodes() throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let json = """
        {
          "object": "validation_result",
          "valid": false,
          "code": "version_not_entitled",
          "message": "This license does not cover version 3.0.1 — it is valid for versions below 3.0.0.",
          "license": {
            "object": "license", "key": "TEST-KEY", "status": "active",
            "starts_at": null, "expires_at": null, "mode": "hardware_locked",
            "plan_key": "personal-lifetime", "seat_limit": 1, "active_seats": 1,
            "active_entitlements": [
              {"key": "updates", "expires_at": null, "below_version": "3.0.0", "metadata": {}}
            ],
            "metadata": {},
            "product": {"object": "product", "slug": "hustl", "name": "Hustl"}
          }
        }
        """.data(using: .utf8)!

        let response = try decoder.decode(ValidationResponse.self, from: json)
        XCTAssertFalse(response.valid)
        XCTAssertEqual(response.code, "version_not_entitled")
        XCTAssertEqual(response.license.activeEntitlements.first?.belowVersion, "3.0.0")
        XCTAssertTrue(response.message?.contains("below 3.0.0") == true)
    }
}
