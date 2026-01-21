import XCTest
import Foundation
#if canImport(CryptoKit)
import CryptoKit
#elseif canImport(Crypto)
import Crypto
#endif
import Combine
@testable import LicenseSeat

@MainActor
final class LicenseSeatSDKTests: XCTestCase {
    private var sdk: LicenseSeat?
    private var cancellables = Set<AnyCancellable>()

    private static let testPrefix = "sdk_integration_test_"
    private static let testProductSlug = "test-app"

    override func setUp() {
        super.setUp()
        URLProtocol.registerClass(MockURLProtocol.self)
        MockURLProtocol.reset()

        let cfg = LicenseSeatConfig(
            apiBaseUrl: "https://api.test.com",
            apiKey: "unit-test",
            productSlug: Self.testProductSlug,
            storagePrefix: Self.testPrefix,
            autoValidateInterval: 3600, // won't trigger in unit time
            offlineFallbackMode: .networkOnly // disable fallback for predictable behavior
        )
        let urlConf = URLSessionConfiguration.ephemeral
        urlConf.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: urlConf)
        sdk = LicenseSeat(config: cfg, urlSession: session)
        sdk?.cache.clear() // clean slate
    }

    override func tearDown() {
        sdk?.cache.clear()
        URLProtocol.unregisterClass(MockURLProtocol.self)
        cancellables.removeAll()
        super.tearDown()
    }

    /// Helper to create a mock activation response
    private func makeActivationResponse(licenseKey: String, deviceId: String) -> [String: Any] {
        return [
            "object": "activation",
            "id": 12345,
            "device_id": deviceId,
            "device_name": "Test Device",
            "license_key": licenseKey,
            "activated_at": ISO8601DateFormatter().string(from: Date()),
            "deactivated_at": NSNull(),
            "ip_address": "127.0.0.1",
            "metadata": NSNull(),
            "license": [
                "object": "license",
                "key": licenseKey,
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
            ]
        ]
    }

    /// Helper to create a mock validation response
    private func makeValidationResponse(valid: Bool, licenseKey: String) -> [String: Any] {
        return [
            "object": "validation_result",
            "valid": valid,
            "code": valid ? NSNull() : "license_expired",
            "message": valid ? NSNull() : "License has expired",
            "warnings": NSNull(),
            "license": [
                "object": "license",
                "key": licenseKey,
                "status": valid ? "active" : "expired",
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
        ]
    }

    /// Helper to create a mock deactivation response
    private func makeDeactivationResponse() -> [String: Any] {
        return [
            "object": "deactivation",
            "activation_id": 12345,
            "deactivated_at": ISO8601DateFormatter().string(from: Date())
        ]
    }

    func testActivationValidationDeactivationFlow() async throws {
        let licenseKey = "TEST-KEY"
        var requestSequence = [String]()

        MockURLProtocol.requestHandler = { request in
            guard let url = request.url else {
                throw URLError(.badURL)
            }
            requestSequence.append(url.path)

            // New v1 API paths: /products/{slug}/licenses/{key}/activate|validate|deactivate
            if url.path.contains("/activate") {
                let data = try JSONSerialization.data(withJSONObject: self.makeActivationResponse(licenseKey: licenseKey, deviceId: "test-device"))
                guard let resp = HTTPURLResponse(url: url, statusCode: 201, httpVersion: nil, headerFields: ["Content-Type": "application/json"]) else {
                    throw URLError(.badServerResponse)
                }
                return (resp, data)
            } else if url.path.contains("/validate") {
                let data = try JSONSerialization.data(withJSONObject: self.makeValidationResponse(valid: true, licenseKey: licenseKey))
                guard let resp = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"]) else {
                    throw URLError(.badServerResponse)
                }
                return (resp, data)
            } else if url.path.contains("/deactivate") {
                let data = try JSONSerialization.data(withJSONObject: self.makeDeactivationResponse())
                guard let resp = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"]) else {
                    throw URLError(.badServerResponse)
                }
                return (resp, data)
            } else {
                guard let resp = HTTPURLResponse(url: url, statusCode: 404, httpVersion: nil, headerFields: nil) else {
                    throw URLError(.badServerResponse)
                }
                return (resp, Data())
            }
        }

        // Expectation for event emissions
        let activationExp = expectation(description: "activation")
        let validationExp = expectation(description: "validation")
        let deactivationExp = expectation(description: "deactivation")

        sdk?.on("activation:success") { _ in activationExp.fulfill() }.store(in: &cancellables)
        sdk?.on("validation:success") { _ in validationExp.fulfill() }.store(in: &cancellables)
        sdk?.on("deactivation:success") { _ in deactivationExp.fulfill() }.store(in: &cancellables)

        // 1. Activate
        let license = try await sdk?.activate(licenseKey: licenseKey)
        XCTAssertEqual(license?.licenseKey, licenseKey)
        XCTAssertNotNil(sdk?.currentLicense())
        XCTAssertEqual(license?.activationId, 12345)

        // 2. Validate
        let validation = try await sdk?.validate(licenseKey: licenseKey)
        XCTAssertTrue(validation?.valid ?? false)

        // 3. Deactivate
        try await sdk?.deactivate()
        XCTAssertNil(sdk?.currentLicense())

        // Wait for events
        await fulfillment(of: [activationExp, validationExp, deactivationExp], timeout: 5)

        // Ensure correct endpoints called in order
        XCTAssertGreaterThanOrEqual(requestSequence.count, 3)
        // Should be product-scoped URLs
        XCTAssertTrue(requestSequence[0].contains("/products/\(Self.testProductSlug)/licenses/\(licenseKey)/activate"))
        XCTAssertTrue(requestSequence[1].contains("/products/\(Self.testProductSlug)/licenses/\(licenseKey)/validate"))
        XCTAssertTrue(requestSequence.last?.contains("/products/\(Self.testProductSlug)/licenses/\(licenseKey)/deactivate") ?? false)
    }

    func testProductSlugRequired() async {
        // Create SDK without product slug
        let cfg = LicenseSeatConfig(
            apiBaseUrl: "https://api.test.com",
            apiKey: "unit-test",
            productSlug: nil,
            storagePrefix: "no_slug_test_"
        )
        let urlConf = URLSessionConfiguration.ephemeral
        urlConf.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: urlConf)
        let sdkNoSlug = LicenseSeat(config: cfg, urlSession: session)

        do {
            _ = try await sdkNoSlug.activate(licenseKey: "TEST-KEY")
            XCTFail("Expected productSlugRequired error")
        } catch let error as LicenseSeatError {
            XCTAssertEqual(error, .productSlugRequired)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testStatusReflectsValidation() async throws {
        let licenseKey = "TEST-KEY"

        MockURLProtocol.requestHandler = { request in
            guard let url = request.url else { throw URLError(.badURL) }

            if url.path.contains("/activate") {
                let data = try JSONSerialization.data(withJSONObject: self.makeActivationResponse(licenseKey: licenseKey, deviceId: "test-device"))
                return (HTTPURLResponse(url: url, statusCode: 201, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, data)
            } else if url.path.contains("/validate") {
                let data = try JSONSerialization.data(withJSONObject: self.makeValidationResponse(valid: true, licenseKey: licenseKey))
                return (HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, data)
            }

            return (HTTPURLResponse(url: url, statusCode: 404, httpVersion: nil, headerFields: nil)!, Data())
        }

        // Initial status should be inactive
        var status = sdk?.getStatus()
        if case .inactive = status {
            // Expected
        } else {
            XCTFail("Expected inactive status, got \(String(describing: status))")
        }

        // After activation
        _ = try await sdk?.activate(licenseKey: licenseKey)
        status = sdk?.getStatus()
        if case .pending = status {
            // Expected - no validation yet
        } else if case .active = status {
            // Also acceptable if validation was cached
        } else {
            XCTFail("Expected pending or active status, got \(String(describing: status))")
        }

        // After validation
        _ = try await sdk?.validate(licenseKey: licenseKey)
        status = sdk?.getStatus()
        if case .active(let details) = status {
            XCTAssertEqual(details.license, licenseKey)
        } else {
            XCTFail("Expected active status, got \(String(describing: status))")
        }
    }

    func testEntitlementChecking() async throws {
        let licenseKey = "TEST-KEY"

        // Validation response with entitlements
        let validationWithEntitlements: [String: Any] = [
            "object": "validation_result",
            "valid": true,
            "code": NSNull(),
            "message": NSNull(),
            "warnings": NSNull(),
            "license": [
                "object": "license",
                "key": licenseKey,
                "status": "active",
                "starts_at": NSNull(),
                "expires_at": NSNull(),
                "mode": "hardware_locked",
                "plan_key": "pro",
                "seat_limit": 5,
                "active_seats": 1,
                "active_entitlements": [
                    ["key": "pro-features", "expires_at": NSNull(), "metadata": NSNull()],
                    ["key": "api-access", "expires_at": NSNull(), "metadata": NSNull()]
                ],
                "metadata": NSNull(),
                "product": ["slug": Self.testProductSlug, "name": "Test App"]
            ],
            "activation": NSNull()
        ]

        MockURLProtocol.requestHandler = { request in
            guard let url = request.url else { throw URLError(.badURL) }

            if url.path.contains("/activate") {
                let data = try JSONSerialization.data(withJSONObject: self.makeActivationResponse(licenseKey: licenseKey, deviceId: "test-device"))
                return (HTTPURLResponse(url: url, statusCode: 201, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, data)
            } else if url.path.contains("/validate") {
                let data = try JSONSerialization.data(withJSONObject: validationWithEntitlements)
                return (HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, data)
            }

            return (HTTPURLResponse(url: url, statusCode: 404, httpVersion: nil, headerFields: nil)!, Data())
        }

        _ = try await sdk?.activate(licenseKey: licenseKey)
        _ = try await sdk?.validate(licenseKey: licenseKey)

        // Check entitlements
        let proStatus = sdk?.checkEntitlement("pro-features")
        XCTAssertTrue(proStatus?.active ?? false)

        let apiStatus = sdk?.checkEntitlement("api-access")
        XCTAssertTrue(apiStatus?.active ?? false)

        let missingStatus = sdk?.checkEntitlement("non-existent")
        XCTAssertFalse(missingStatus?.active ?? true)
        XCTAssertEqual(missingStatus?.reason, .notFound)
    }

    func testAPIErrorHandling() async throws {
        // Configure mock to return error
        MockURLProtocol.requestHandler = { request in
            guard let url = request.url else { throw URLError(.badURL) }

            let errorResponse: [String: Any] = [
                "error": [
                    "code": "license_not_found",
                    "message": "License key not found"
                ]
            ]

            let data = try JSONSerialization.data(withJSONObject: errorResponse)
            return (HTTPURLResponse(url: url, statusCode: 404, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, data)
        }

        do {
            _ = try await sdk?.activate(licenseKey: "INVALID-KEY")
            XCTFail("Expected error to be thrown")
        } catch let error as APIError {
            XCTAssertEqual(error.code, "license_not_found")
            XCTAssertEqual(error.message, "License key not found")
            XCTAssertEqual(error.status, 404)
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }
}
