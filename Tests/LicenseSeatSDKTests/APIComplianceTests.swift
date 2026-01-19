///
/// APIComplianceTests.swift
/// LicenseSeatSDKTests
///
/// Comprehensive regression tests for API compliance fixes.
/// These tests verify that the SDK correctly handles various API response formats
/// and ensure bug fixes don't regress.
///

import XCTest
import Foundation
@testable import LicenseSeat

// MARK: - ActivationResult ID Type Tests

/// Tests for ActivationResult.id type flexibility (API can return Int or String)
final class ActivationResultDecodingTests: XCTestCase {

    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    /// API returns id as String - should decode correctly
    func testDecodesStringId() throws {
        let json = """
        {
            "id": "act-123-abc",
            "activated_at": "2025-01-15T10:00:00Z"
        }
        """

        let result = try decoder.decode(ActivationResult.self, from: Data(json.utf8))

        XCTAssertEqual(result.id, "act-123-abc")
    }

    /// API returns id as Int - should decode and convert to String
    func testDecodesIntId() throws {
        let json = """
        {
            "id": 12345,
            "activated_at": "2025-01-15T10:00:00Z"
        }
        """

        let result = try decoder.decode(ActivationResult.self, from: Data(json.utf8))

        XCTAssertEqual(result.id, "12345")
    }

    /// API returns id as large Int - should handle without overflow
    func testDecodesLargeIntId() throws {
        let json = """
        {
            "id": 9223372036854775807,
            "activated_at": "2025-01-15T10:00:00Z"
        }
        """

        let result = try decoder.decode(ActivationResult.self, from: Data(json.utf8))

        XCTAssertEqual(result.id, "9223372036854775807")
    }

    /// API returns id as zero - edge case
    func testDecodesZeroIntId() throws {
        let json = """
        {
            "id": 0,
            "activated_at": "2025-01-15T10:00:00Z"
        }
        """

        let result = try decoder.decode(ActivationResult.self, from: Data(json.utf8))

        XCTAssertEqual(result.id, "0")
    }

    /// API returns id as empty string - edge case
    func testDecodesEmptyStringId() throws {
        let json = """
        {
            "id": "",
            "activated_at": "2025-01-15T10:00:00Z"
        }
        """

        let result = try decoder.decode(ActivationResult.self, from: Data(json.utf8))

        XCTAssertEqual(result.id, "")
    }

    /// Missing id field should throw error
    func testThrowsOnMissingId() {
        let json = """
        {
            "activated_at": "2025-01-15T10:00:00Z"
        }
        """

        XCTAssertThrowsError(try decoder.decode(ActivationResult.self, from: Data(json.utf8)))
    }

    /// Invalid id type (e.g., boolean) should throw error
    func testThrowsOnInvalidIdType() {
        let json = """
        {
            "id": true,
            "activated_at": "2025-01-15T10:00:00Z"
        }
        """

        XCTAssertThrowsError(try decoder.decode(ActivationResult.self, from: Data(json.utf8)))
    }

    /// ActivationResult should encode id as String
    func testEncodesIdAsString() throws {
        let result = ActivationResult(id: "12345", activatedAt: Date())

        let encoder = JSONEncoder()
        let data = try encoder.encode(result)
        let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        // Verify id is encoded as String
        XCTAssertTrue(dict?["id"] is String)
        XCTAssertEqual(dict?["id"] as? String, "12345")
    }
}

// MARK: - LicenseValidationResult Entitlement Parsing Tests

/// Tests for LicenseValidationResult entitlement parsing from various API formats
final class LicenseValidationResultDecodingTests: XCTestCase {

    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    // MARK: - Top-level active_entitlements (direct format)

    /// Standard format with entitlements at top level
    func testDecodesTopLevelEntitlements() throws {
        let json = """
        {
            "valid": true,
            "offline": false,
            "active_entitlements": [
                {
                    "key": "pro-features",
                    "name": "Pro Features",
                    "description": "Access to all pro features"
                },
                {
                    "key": "api-access",
                    "name": "API Access"
                }
            ]
        }
        """

        let result = try decoder.decode(LicenseValidationResult.self, from: Data(json.utf8))

        XCTAssertTrue(result.valid)
        XCTAssertFalse(result.offline)
        XCTAssertEqual(result.activeEntitlements?.count, 2)
        XCTAssertEqual(result.activeEntitlements?[0].key, "pro-features")
        XCTAssertEqual(result.activeEntitlements?[0].name, "Pro Features")
        XCTAssertEqual(result.activeEntitlements?[1].key, "api-access")
    }

    // MARK: - Nested license.active_entitlements (API /licenses/validate format)

    /// API validation response format: entitlements nested inside "license" object
    /// This is the CRITICAL fix - the API returns: { "valid": true, "license": { "active_entitlements": [...] } }
    func testDecodesNestedLicenseEntitlements() throws {
        let json = """
        {
            "valid": true,
            "offline": false,
            "license": {
                "active_entitlements": [
                    {
                        "key": "premium",
                        "name": "Premium Plan",
                        "expires_at": "2026-12-31T23:59:59Z"
                    }
                ],
                "license_key": "TEST-KEY-123",
                "status": "active"
            }
        }
        """

        let result = try decoder.decode(LicenseValidationResult.self, from: Data(json.utf8))

        XCTAssertTrue(result.valid)
        XCTAssertFalse(result.offline)
        XCTAssertEqual(result.activeEntitlements?.count, 1)
        XCTAssertEqual(result.activeEntitlements?[0].key, "premium")
        XCTAssertEqual(result.activeEntitlements?[0].name, "Premium Plan")
        XCTAssertNotNil(result.activeEntitlements?[0].expiresAt)
    }

    /// Real-world API response with full license object
    func testDecodesRealWorldAPIResponse() throws {
        let json = """
        {
            "valid": true,
            "offline": false,
            "reason": null,
            "reason_code": null,
            "license": {
                "license_key": "LS-PRO-2025-ABCD",
                "status": "active",
                "created_at": "2025-01-01T00:00:00Z",
                "expires_at": "2026-01-01T00:00:00Z",
                "active_entitlements": [
                    {
                        "key": "feature-a",
                        "name": "Feature A"
                    },
                    {
                        "key": "feature-b",
                        "name": "Feature B",
                        "expires_at": "2025-06-30T23:59:59Z"
                    },
                    {
                        "key": "feature-c",
                        "name": "Feature C",
                        "description": "Advanced analytics",
                        "metadata": {
                            "limit": 1000,
                            "tier": "enterprise"
                        }
                    }
                ]
            }
        }
        """

        let result = try decoder.decode(LicenseValidationResult.self, from: Data(json.utf8))

        XCTAssertTrue(result.valid)
        XCTAssertEqual(result.activeEntitlements?.count, 3)

        // Verify first entitlement
        XCTAssertEqual(result.activeEntitlements?[0].key, "feature-a")

        // Verify second entitlement has expiration
        XCTAssertEqual(result.activeEntitlements?[1].key, "feature-b")
        XCTAssertNotNil(result.activeEntitlements?[1].expiresAt)

        // Verify third entitlement has metadata
        XCTAssertEqual(result.activeEntitlements?[2].key, "feature-c")
        XCTAssertEqual(result.activeEntitlements?[2].description, "Advanced analytics")
        XCTAssertNotNil(result.activeEntitlements?[2].metadata)
    }

    /// Nested format takes precedence when both exist (edge case)
    func testPrefersTopLevelOverNested() throws {
        // If both top-level and nested exist, top-level should be used
        let json = """
        {
            "valid": true,
            "offline": false,
            "active_entitlements": [
                {"key": "top-level"}
            ],
            "license": {
                "active_entitlements": [
                    {"key": "nested"}
                ]
            }
        }
        """

        let result = try decoder.decode(LicenseValidationResult.self, from: Data(json.utf8))

        // Top-level is checked first, so it should be used
        XCTAssertEqual(result.activeEntitlements?.count, 1)
        XCTAssertEqual(result.activeEntitlements?[0].key, "top-level")
    }

    // MARK: - Offline payload abbreviated keys (active_ents)

    /// Offline payload uses abbreviated key "active_ents"
    func testDecodesOfflinePayloadAbbreviatedKeys() throws {
        let json = """
        {
            "valid": true,
            "offline": true,
            "active_ents": [
                {
                    "key": "offline-feature",
                    "name": "Offline Feature",
                    "expires_at": "2026-06-15T12:00:00Z"
                }
            ]
        }
        """

        let result = try decoder.decode(LicenseValidationResult.self, from: Data(json.utf8))

        XCTAssertTrue(result.valid)
        XCTAssertTrue(result.offline)
        XCTAssertEqual(result.activeEntitlements?.count, 1)
        XCTAssertEqual(result.activeEntitlements?[0].key, "offline-feature")
    }

    // MARK: - Empty and null entitlements

    /// Empty entitlements array should be preserved (not nil)
    func testDecodesEmptyEntitlements() throws {
        let json = """
        {
            "valid": true,
            "offline": false,
            "active_entitlements": []
        }
        """

        let result = try decoder.decode(LicenseValidationResult.self, from: Data(json.utf8))

        XCTAssertTrue(result.valid)
        XCTAssertNotNil(result.activeEntitlements)
        XCTAssertEqual(result.activeEntitlements?.count, 0)
    }

    /// Missing entitlements field should result in nil
    func testDecodesMissingEntitlements() throws {
        let json = """
        {
            "valid": true,
            "offline": false
        }
        """

        let result = try decoder.decode(LicenseValidationResult.self, from: Data(json.utf8))

        XCTAssertTrue(result.valid)
        XCTAssertNil(result.activeEntitlements)
    }

    /// Null entitlements should result in nil
    func testDecodesNullEntitlements() throws {
        let json = """
        {
            "valid": true,
            "offline": false,
            "active_entitlements": null
        }
        """

        let result = try decoder.decode(LicenseValidationResult.self, from: Data(json.utf8))

        XCTAssertTrue(result.valid)
        XCTAssertNil(result.activeEntitlements)
    }

    // MARK: - Invalid license with reason

    /// Invalid license with reason and reason_code
    func testDecodesInvalidLicenseWithReason() throws {
        let json = """
        {
            "valid": false,
            "offline": false,
            "reason": "License has expired",
            "reason_code": "license_expired"
        }
        """

        let result = try decoder.decode(LicenseValidationResult.self, from: Data(json.utf8))

        XCTAssertFalse(result.valid)
        XCTAssertEqual(result.reason, "License has expired")
        XCTAssertEqual(result.reasonCode, "license_expired")
    }

    // MARK: - Optimistic validation

    /// Optimistic validation flag
    func testDecodesOptimisticFlag() throws {
        let json = """
        {
            "valid": true,
            "offline": true,
            "optimistic": true
        }
        """

        let result = try decoder.decode(LicenseValidationResult.self, from: Data(json.utf8))

        XCTAssertTrue(result.valid)
        XCTAssertTrue(result.optimistic ?? false)
    }

    // MARK: - Encoding

    /// LicenseValidationResult should encode correctly
    func testEncodesCorrectly() throws {
        let entitlement = Entitlement(
            key: "test",
            name: "Test",
            description: nil,
            expiresAt: nil,
            metadata: nil
        )
        let result = LicenseValidationResult(
            valid: true,
            reason: nil,
            offline: false,
            reasonCode: nil,
            optimistic: nil,
            activeEntitlements: [entitlement]
        )

        let encoder = JSONEncoder()
        let data = try encoder.encode(result)
        let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        XCTAssertEqual(dict?["valid"] as? Bool, true)
        XCTAssertEqual(dict?["offline"] as? Bool, false)
        XCTAssertNotNil(dict?["active_entitlements"])
    }
}

// MARK: - Configuration Tests

/// Tests for LicenseSeatConfig and single source of truth for base URL
final class ConfigurationTests: XCTestCase {

    /// Production URL constant should be correct
    func testProductionAPIBaseURLConstant() {
        XCTAssertEqual(LicenseSeatConfig.productionAPIBaseURL, "https://licenseseat.com/api")
    }

    /// Default config should use production URL constant
    func testDefaultConfigUsesProductionURL() {
        let config = LicenseSeatConfig.default
        XCTAssertEqual(config.apiBaseUrl, LicenseSeatConfig.productionAPIBaseURL)
        XCTAssertEqual(config.apiBaseUrl, "https://licenseseat.com/api")
    }

    /// Init without parameters should use production URL
    func testInitWithoutParametersUsesProductionURL() {
        let config = LicenseSeatConfig()
        XCTAssertEqual(config.apiBaseUrl, LicenseSeatConfig.productionAPIBaseURL)
    }

    /// Custom URL should override default
    func testCustomURLOverridesDefault() {
        let config = LicenseSeatConfig(apiBaseUrl: "https://custom.api.com")
        XCTAssertEqual(config.apiBaseUrl, "https://custom.api.com")
    }

    /// All config options should have sensible defaults
    func testDefaultConfigValues() {
        let config = LicenseSeatConfig.default

        XCTAssertNil(config.apiKey)
        XCTAssertEqual(config.storagePrefix, "licenseseat_")
        XCTAssertNil(config.deviceIdentifier)
        XCTAssertEqual(config.autoValidateInterval, 3600) // 1 hour
        XCTAssertEqual(config.networkRecheckInterval, 30)
        XCTAssertEqual(config.maxRetries, 3)
        XCTAssertEqual(config.retryDelay, 1)
        XCTAssertFalse(config.debug)
        XCTAssertEqual(config.offlineLicenseRefreshInterval, 259200) // 72 hours
        XCTAssertEqual(config.maxOfflineDays, 0)
        XCTAssertEqual(config.maxClockSkewMs, 300000) // 5 minutes
    }

    /// Offline fallback mode mapping should work correctly
    func testOfflineFallbackModeMapping() {
        var config = LicenseSeatConfig.default

        // Default should be networkOnly (offlineFallbackEnabled: false -> networkOnly)
        XCTAssertEqual(config.offlineFallbackMode, .networkOnly)
        XCTAssertTrue(config.strictOfflineFallback)

        // Setting strictOfflineFallback to false should change to always
        config.strictOfflineFallback = false
        XCTAssertEqual(config.offlineFallbackMode, .always)

        // Setting strictOfflineFallback to true should change to networkOnly
        config.strictOfflineFallback = true
        XCTAssertEqual(config.offlineFallbackMode, .networkOnly)
    }
}

// MARK: - Error Response Handling Tests

/// Tests for error response handling with reason_code
@MainActor
final class ErrorResponseHandlingTests: XCTestCase {

    private var sdk: LicenseSeat?
    private static let testPrefix = "error_test_"

    override func setUp() async throws {
        try await super.setUp()
        URLProtocol.registerClass(MockURLProtocol.self)
        MockURLProtocol.reset()

        let cfg = LicenseSeatConfig(
            apiBaseUrl: "https://api.test.com",
            apiKey: "test-key",
            storagePrefix: Self.testPrefix,
            autoValidateInterval: 0
        )
        let urlConf = URLSessionConfiguration.ephemeral
        urlConf.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: urlConf)
        sdk = LicenseSeat(config: cfg, urlSession: session)
        sdk?.cache.clear()
    }

    override func tearDown() async throws {
        sdk?.cache.clear()
        URLProtocol.unregisterClass(MockURLProtocol.self)
        try await super.tearDown()
    }

    /// Error response with reason_code should be properly parsed
    func testAPIErrorWithReasonCode() async {
        let errorJSON: [String: Any] = [
            "error": "License key not found",
            "reason_code": "license_not_found"
        ]

        MockURLProtocol.requestHandler = { request in
            let data = try JSONSerialization.data(withJSONObject: errorJSON)
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 404,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, data)
        }

        do {
            _ = try await sdk?.activate(licenseKey: "INVALID-KEY")
            XCTFail("Expected error to be thrown")
        } catch let error as APIError {
            XCTAssertEqual(error.message, "License key not found")
            XCTAssertEqual(error.reasonCode, "license_not_found")
            XCTAssertEqual(error.status, 404)
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    /// Error response without reason_code should still work
    func testAPIErrorWithoutReasonCode() async {
        let errorJSON: [String: Any] = [
            "error": "Internal server error"
        ]

        MockURLProtocol.requestHandler = { request in
            let data = try JSONSerialization.data(withJSONObject: errorJSON)
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 500,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, data)
        }

        do {
            _ = try await sdk?.activate(licenseKey: "TEST-KEY")
            XCTFail("Expected error to be thrown")
        } catch let error as APIError {
            XCTAssertEqual(error.message, "Internal server error")
            XCTAssertNil(error.reasonCode)
            XCTAssertEqual(error.status, 500)
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    /// Various error reason codes from the API
    func testVariousReasonCodes() async {
        let testCases: [(code: String, status: Int, message: String)] = [
            ("license_expired", 403, "License has expired"),
            ("license_suspended", 403, "License is suspended"),
            ("activation_limit_reached", 403, "Activation limit reached"),
            ("device_not_activated", 403, "Device is not activated"),
            ("invalid_license_key", 400, "Invalid license key format"),
            ("product_mismatch", 403, "Product does not match license")
        ]

        for testCase in testCases {
            let errorJSON: [String: Any] = [
                "error": testCase.message,
                "reason_code": testCase.code
            ]

            MockURLProtocol.requestHandler = { request in
                let data = try JSONSerialization.data(withJSONObject: errorJSON)
                let response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: testCase.status,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!
                return (response, data)
            }

            do {
                _ = try await sdk?.activate(licenseKey: "TEST-KEY")
                XCTFail("Expected error to be thrown for \(testCase.code)")
            } catch let error as APIError {
                XCTAssertEqual(error.reasonCode, testCase.code, "Reason code mismatch for \(testCase.code)")
                XCTAssertEqual(error.status, testCase.status, "Status mismatch for \(testCase.code)")
            } catch {
                XCTFail("Unexpected error type for \(testCase.code): \(error)")
            }
        }
    }
}

// MARK: - Integration Tests for API Response Formats

/// Integration tests that verify the full flow with various API response formats
@MainActor
final class APIResponseIntegrationTests: XCTestCase {

    private var sdk: LicenseSeat?
    private static let testPrefix = "api_integration_test_"

    override func setUp() async throws {
        try await super.setUp()
        URLProtocol.registerClass(MockURLProtocol.self)
        MockURLProtocol.reset()

        let cfg = LicenseSeatConfig(
            apiBaseUrl: "https://api.test.com",
            apiKey: "test-key",
            storagePrefix: Self.testPrefix,
            autoValidateInterval: 0
        )
        let urlConf = URLSessionConfiguration.ephemeral
        urlConf.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: urlConf)
        sdk = LicenseSeat(config: cfg, urlSession: session)
        sdk?.cache.clear()
    }

    override func tearDown() async throws {
        sdk?.cache.clear()
        URLProtocol.unregisterClass(MockURLProtocol.self)
        try await super.tearDown()
    }

    /// Test activation with Int ID from API
    func testActivationWithIntId() async throws {
        let activationJSON: [String: Any] = [
            "id": 98765,  // Int ID
            "activated_at": ISO8601DateFormatter().string(from: Date())
        ]

        MockURLProtocol.requestHandler = { request in
            let data = try JSONSerialization.data(withJSONObject: activationJSON)
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, data)
        }

        let license = try await sdk?.activate(licenseKey: "TEST-KEY")

        XCTAssertEqual(license?.activation.id, "98765")
    }

    /// Test activation with String ID from API
    func testActivationWithStringId() async throws {
        let activationJSON: [String: Any] = [
            "id": "act-uuid-12345",  // String ID
            "activated_at": ISO8601DateFormatter().string(from: Date())
        ]

        MockURLProtocol.requestHandler = { request in
            let data = try JSONSerialization.data(withJSONObject: activationJSON)
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, data)
        }

        let license = try await sdk?.activate(licenseKey: "TEST-KEY")

        XCTAssertEqual(license?.activation.id, "act-uuid-12345")
    }

    /// Test validation with nested entitlements (API format)
    func testValidationWithNestedEntitlements() async throws {
        // First activate
        let activationJSON: [String: Any] = [
            "id": "123",
            "activated_at": ISO8601DateFormatter().string(from: Date())
        ]

        // Then validate with nested entitlements
        let validationJSON: [String: Any] = [
            "valid": true,
            "offline": false,
            "license": [
                "license_key": "TEST-KEY",
                "active_entitlements": [
                    ["key": "feature-1", "name": "Feature One"],
                    ["key": "feature-2", "name": "Feature Two"]
                ]
            ]
        ]

        var requestCount = 0
        MockURLProtocol.requestHandler = { request in
            requestCount += 1
            let json: [String: Any]
            if request.url?.path == "/activations/activate" {
                json = activationJSON
            } else {
                json = validationJSON
            }
            let data = try JSONSerialization.data(withJSONObject: json)
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, data)
        }

        // Activate first
        _ = try await sdk?.activate(licenseKey: "TEST-KEY")

        // Then validate
        let validation = try await sdk?.validate(licenseKey: "TEST-KEY")

        XCTAssertTrue(validation?.valid ?? false)
        XCTAssertEqual(validation?.activeEntitlements?.count, 2)
        XCTAssertEqual(validation?.activeEntitlements?[0].key, "feature-1")
        XCTAssertEqual(validation?.activeEntitlements?[1].key, "feature-2")
    }

    /// Test entitlement checking after validation with nested response
    func testEntitlementCheckingAfterNestedValidation() async throws {
        let activationJSON: [String: Any] = [
            "id": "123",
            "activated_at": ISO8601DateFormatter().string(from: Date())
        ]

        let validationJSON: [String: Any] = [
            "valid": true,
            "offline": false,
            "license": [
                "active_entitlements": [
                    ["key": "pro-features", "name": "Pro Features"],
                    ["key": "api-access", "name": "API Access"]
                ]
            ]
        ]

        MockURLProtocol.requestHandler = { request in
            let json: [String: Any]
            if request.url?.path == "/activations/activate" {
                json = activationJSON
            } else {
                json = validationJSON
            }
            let data = try JSONSerialization.data(withJSONObject: json)
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, data)
        }

        _ = try await sdk?.activate(licenseKey: "TEST-KEY")
        _ = try await sdk?.validate(licenseKey: "TEST-KEY")

        // Check entitlements
        let proStatus = sdk?.checkEntitlement("pro-features")
        let apiStatus = sdk?.checkEntitlement("api-access")
        let missingStatus = sdk?.checkEntitlement("non-existent")

        XCTAssertTrue(proStatus?.active ?? false)
        XCTAssertTrue(apiStatus?.active ?? false)
        XCTAssertFalse(missingStatus?.active ?? true)
        XCTAssertEqual(missingStatus?.reason, .notFound)
    }
}

// MARK: - Entitlement Decoding Tests

/// Tests for Entitlement struct decoding
final class EntitlementDecodingTests: XCTestCase {

    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    /// Basic entitlement with all fields
    func testDecodesFullEntitlement() throws {
        let json = """
        {
            "key": "premium",
            "name": "Premium Plan",
            "description": "Access to all premium features",
            "expires_at": "2026-12-31T23:59:59Z",
            "metadata": {
                "tier": "gold",
                "seats": 5
            }
        }
        """

        let entitlement = try decoder.decode(Entitlement.self, from: Data(json.utf8))

        XCTAssertEqual(entitlement.key, "premium")
        XCTAssertEqual(entitlement.name, "Premium Plan")
        XCTAssertEqual(entitlement.description, "Access to all premium features")
        XCTAssertNotNil(entitlement.expiresAt)
        XCTAssertNotNil(entitlement.metadata)
        XCTAssertEqual(entitlement.metadata?["tier"]?.value as? String, "gold")
        XCTAssertEqual(entitlement.metadata?["seats"]?.value as? Int, 5)
    }

    /// Minimal entitlement with only required fields
    func testDecodesMinimalEntitlement() throws {
        let json = """
        {
            "key": "basic"
        }
        """

        let entitlement = try decoder.decode(Entitlement.self, from: Data(json.utf8))

        XCTAssertEqual(entitlement.key, "basic")
        XCTAssertNil(entitlement.name)
        XCTAssertNil(entitlement.description)
        XCTAssertNil(entitlement.expiresAt)
        XCTAssertNil(entitlement.metadata)
    }

    /// Entitlement with null optional fields
    func testDecodesEntitlementWithNulls() throws {
        let json = """
        {
            "key": "standard",
            "name": null,
            "description": null,
            "expires_at": null,
            "metadata": null
        }
        """

        let entitlement = try decoder.decode(Entitlement.self, from: Data(json.utf8))

        XCTAssertEqual(entitlement.key, "standard")
        XCTAssertNil(entitlement.name)
        XCTAssertNil(entitlement.description)
        XCTAssertNil(entitlement.expiresAt)
        XCTAssertNil(entitlement.metadata)
    }
}
