import XCTest
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(CryptoKit)
import CryptoKit
#elseif canImport(Crypto)
import Crypto
#endif
#if canImport(Combine)
import Combine
#endif
@testable import LicenseSeat

@MainActor
final class LicenseSeatSDKTests: XCTestCase {
    private var sdk: LicenseSeat?
    private var cancellables = Set<AnyCancellable>()

    private static let testProductSlug = "test-app"

    override func setUp() async throws {
        _ = URLProtocol.registerClass(MockURLProtocol.self)
        MockURLProtocol.reset()

        let cfg = LicenseSeatConfig(
            apiBaseUrl: "https://api.test.com",
            apiKey: "unit-test",
            productSlug: Self.testProductSlug,
            storagePrefix: "sdk_integration_test_\(UUID().uuidString)_",
            deviceIdentifier: "test-device",
            autoValidateInterval: 3600, // won't trigger in unit time
            maxRetries: 0,
            offlineFallbackMode: .networkOnly
        )
        let urlConf = URLSessionConfiguration.ephemeral
        urlConf.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: urlConf)
        sdk = LicenseSeat(config: cfg, urlSession: session)
        sdk?.cache.clear() // clean slate
    }

    override func tearDown() async throws {
        sdk?.reset()
        sdk = nil
        URLProtocol.unregisterClass(MockURLProtocol.self)
        cancellables.removeAll()
    }

    /// Helper to create a mock activation response
    private func makeActivationResponse(licenseKey: String, deviceId: String) -> [String: Any] {
        return [
            "object": "activation",
            "id": "act-12345-uuid",
            "fingerprint": deviceId,
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
            "activation_id": "act-12345-uuid",
            "deactivated_at": ISO8601DateFormatter().string(from: Date())
        ]
    }

    private func makeDummyOfflineToken(licenseKey: String) throws -> OfflineTokenResponse {
        let now = Int(Date().timeIntervalSince1970)
        let payload: [String: Any] = [
            "object": "offline_token",
            "token": [
                "schema_version": 1,
                "license_key": licenseKey,
                "product_slug": Self.testProductSlug,
                "plan_key": "pro",
                "mode": "hardware_locked",
                "fingerprint": "test-device",
                "iat": now,
                "exp": now + 3_600,
                "nbf": now,
                "kid": "dummy-key",
                "entitlements": []
            ],
            "signature": [
                "algorithm": "Ed25519",
                "key_id": "dummy-key",
                "value": "not-a-real-signature"
            ],
            "canonical": "{}"
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        return try JSONDecoder().decode(OfflineTokenResponse.self, from: data)
    }

    @discardableResult
    private func cacheValidOfflineGrant(
        on sdk: LicenseSeat,
        licenseKey: String,
        deviceId: String = "test-device",
        activationId: String = "cached-activation",
        cachePublicKey: Bool = true
    ) throws -> (
        offlineToken: OfflineTokenResponse,
        privateKey: Curve25519.Signing.PrivateKey
    ) {
        let privateKey = Curve25519.Signing.PrivateKey()
        let token = try makeSignedOfflineToken(
            licenseKey: licenseKey,
            deviceId: deviceId,
            privateKey: privateKey
        )
        let validationData = try JSONSerialization.data(
            withJSONObject: makeValidationResponse(valid: true, licenseKey: licenseKey)
        )
        let validation = try JSONDecoder().decode(ValidationResponse.self, from: validationData)
        let license = License(
            licenseKey: licenseKey,
            deviceId: deviceId,
            activationId: activationId,
            activatedAt: Date(),
            lastValidated: Date(),
            validation: validation
        )

        guard sdk.cache.setLicense(license),
              sdk.cache.setOfflineToken(token),
              !cachePublicKey || sdk.cache.setPublicKey(
                token.token.kid,
                Base64URL.encode(privateKey.publicKey.rawRepresentation)
              ) else {
            throw LicenseSeatError.cacheError
        }
        return (token, privateKey)
    }

    private func makeSignedOfflineToken(
        licenseKey: String,
        deviceId: String = "test-device",
        privateKey: Curve25519.Signing.PrivateKey
    ) throws -> OfflineTokenResponse {
        let now = Int(Date().timeIntervalSince1970)
        let kid = "offline-key-\(licenseKey)"
        let payload = OfflineTokenResponse.TokenPayload(
            schemaVersion: 1,
            licenseKey: licenseKey,
            productSlug: Self.testProductSlug,
            planKey: "pro",
            mode: "hardware_locked",
            seatLimit: 5,
            deviceId: deviceId,
            iat: now,
            exp: now + 3_600,
            nbf: now,
            licenseExpiresAt: nil,
            kid: kid,
            entitlements: [],
            metadata: nil
        )
        let encodedPayload = try JSONEncoder().encode(payload)
        let payloadObject = try JSONSerialization.jsonObject(with: encodedPayload)
        let canonical = try CanonicalJSON.stringify(payloadObject)
        let signature = try privateKey.signature(for: Data(canonical.utf8))
        let token = OfflineTokenResponse(
            object: "offline_token",
            token: payload,
            signature: .init(
                algorithm: "Ed25519",
                keyId: kid,
                value: Base64URL.encode(signature)
            ),
            canonical: canonical
        )
        return token
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
        let license = try await sdk?.activate(
            licenseKey: licenseKey,
            options: ActivationOptions(deviceId: "test-device")
        )
        XCTAssertEqual(license?.licenseKey, licenseKey)
        XCTAssertNotNil(sdk?.currentLicense())
        XCTAssertEqual(license?.activationId, "act-12345-uuid")
        if case .active = sdk?.getStatus() {
            // Activation embeds an authoritative active license response.
        } else {
            XCTFail("A successful activation should be immediately active")
        }

        // 2. Validate
        let validation = try await sdk?.validate(licenseKey: licenseKey)
        XCTAssertTrue(validation?.valid ?? false)

        // 3. Deactivate
        try await sdk?.deactivate()
        XCTAssertNil(sdk?.currentLicense())

        // Wait for events
        await assertFulfillment(
            of: [activationExp, validationExp, deactivationExp],
            timeout: 5
        )

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
            storagePrefix: "no_slug_test_\(UUID().uuidString)_"
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

        // After activation, the embedded license response is authoritative.
        _ = try await sdk?.activate(
            licenseKey: licenseKey,
            options: ActivationOptions(deviceId: "test-device")
        )
        status = sdk?.getStatus()
        if case .active = status {
            // Expected.
        } else {
            XCTFail("Expected active status, got \(String(describing: status))")
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

        _ = try await sdk?.activate(
            licenseKey: licenseKey,
            options: ActivationOptions(deviceId: "test-device")
        )
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

    func testAuthoritativeInvalidValidationRevokesOfflineGrantAndEntitlements() async throws {
        let licenseKey = "TEST-INVALID"
        let invalidValidation: [String: Any] = [
            "object": "validation_result",
            "valid": false,
            "code": "suspended",
            "message": "License has been suspended",
            "warnings": NSNull(),
            "license": [
                "object": "license",
                "key": licenseKey,
                "status": "suspended",
                "starts_at": NSNull(),
                "expires_at": NSNull(),
                "mode": "hardware_locked",
                "plan_key": "pro",
                "seat_limit": 5,
                "active_seats": 1,
                // Even an inconsistent backend payload must never grant this
                // entitlement when the top-level validation is invalid.
                "active_entitlements": [[
                    "key": "pro-features",
                    "expires_at": NSNull(),
                    "metadata": NSNull()
                ]],
                "metadata": NSNull(),
                "product": ["slug": Self.testProductSlug, "name": "Test App"]
            ],
            "activation": NSNull()
        ]

        MockURLProtocol.requestHandler = { request in
            let payload: [String: Any]
            let status: Int
            if request.url!.path.contains("/activate") {
                payload = self.makeActivationResponse(licenseKey: licenseKey, deviceId: "test-device")
                status = 201
            } else if request.url!.path.contains("/validate") {
                payload = invalidValidation
                status = 200
            } else {
                payload = ["error": ["code": "not_available", "message": "Not available"]]
                status = 404
            }
            return (
                HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!,
                try JSONSerialization.data(withJSONObject: payload)
            )
        }

        _ = try await sdk?.activate(
            licenseKey: licenseKey,
            options: ActivationOptions(deviceId: "test-device")
        )
        sdk?.cache.setOfflineToken(try makeDummyOfflineToken(licenseKey: licenseKey))

        let response = try await sdk?.validate(licenseKey: licenseKey)

        XCTAssertFalse(response?.valid ?? true)
        XCTAssertNil(sdk?.cache.getOfflineToken())
        XCTAssertNotNil(sdk?.currentLicense(), "Keep the invalid response for user-facing diagnostics")
        XCTAssertFalse(sdk?.checkEntitlement("pro-features").active ?? true)
        XCTAssertNil(sdk?.validationTask)
        XCTAssertNil(sdk?.heartbeatTask)
        XCTAssertNil(sdk?.offlineRefreshTimer)
        if case .invalid(let message) = sdk?.getStatus() {
            XCTAssertEqual(message, "License has been suspended")
        } else {
            XCTFail("Expected invalid status after authoritative online rejection")
        }
    }

    func testForbiddenScopeErrorDoesNotEraseCachedLicense() async throws {
        let licenseKey = "TEST-FORBIDDEN"
        var activated = false
        MockURLProtocol.requestHandler = { request in
            if request.url!.path.contains("/activate"), !activated {
                activated = true
                let payload = self.makeActivationResponse(
                    licenseKey: licenseKey,
                    deviceId: "test-device"
                )
                return (
                    HTTPURLResponse(url: request.url!, statusCode: 201, httpVersion: nil, headerFields: nil)!,
                    try JSONSerialization.data(withJSONObject: payload)
                )
            }

            let payload = ["error": ["code": "forbidden", "message": "Missing validation scope"]]
            return (
                HTTPURLResponse(url: request.url!, statusCode: 403, httpVersion: nil, headerFields: nil)!,
                try JSONSerialization.data(withJSONObject: payload)
            )
        }

        _ = try await sdk?.activate(
            licenseKey: licenseKey,
            options: ActivationOptions(deviceId: "test-device")
        )

        do {
            _ = try await sdk?.validate(licenseKey: licenseKey)
            XCTFail("Expected forbidden response")
        } catch let error as APIError {
            XCTAssertEqual(error.status, 403)
        }

        XCTAssertEqual(sdk?.currentLicense()?.licenseKey, licenseKey)
        if case .active = sdk?.getStatus() {
            // Cached signed/online state remains available for a scope error.
        } else {
            XCTFail("A scope error must not revoke the cached license")
        }
    }

    func testFailedOfflineFallbackReportsOfflineInvalidStatus() async throws {
        let licenseKey = "TEST-OFFLINE-INVALID"
        var activated = false
        MockURLProtocol.requestHandler = { request in
            if request.url!.path.contains("/activate"), !activated {
                activated = true
                let payload = self.makeActivationResponse(
                    licenseKey: licenseKey,
                    deviceId: "test-device"
                )
                return (
                    HTTPURLResponse(
                        url: request.url!,
                        statusCode: 201,
                        httpVersion: nil,
                        headerFields: nil
                    )!,
                    try JSONSerialization.data(withJSONObject: payload)
                )
            }
            throw URLError(.notConnectedToInternet)
        }

        _ = try await sdk?.activate(
            licenseKey: licenseKey,
            options: ActivationOptions(deviceId: "test-device")
        )
        sdk?.cache.clearOfflineToken()

        do {
            _ = try await sdk?.validate(licenseKey: licenseKey)
            XCTFail("Expected the original transport error")
        } catch let error as URLError {
            XCTAssertEqual(error.code, .notConnectedToInternet)
        }

        if case .offlineInvalid(let message) = sdk?.getStatus() {
            XCTAssertEqual(message, "Offline validation: no_offline_token")
        } else {
            XCTFail("A failed offline fallback should be distinguishable from an online rejection")
        }
    }

    func testTerminalAPIErrorPurgesAllCachedLicenseState() async throws {
        let licenseKey = "TEST-SUSPENDED"
        var activated = false
        MockURLProtocol.requestHandler = { request in
            if request.url!.path.contains("/activate"), !activated {
                activated = true
                let payload = self.makeActivationResponse(
                    licenseKey: licenseKey,
                    deviceId: "test-device"
                )
                return (
                    HTTPURLResponse(url: request.url!, statusCode: 201, httpVersion: nil, headerFields: nil)!,
                    try JSONSerialization.data(withJSONObject: payload)
                )
            }
            let payload = [
                "error": ["code": "license_suspended", "message": "License suspended"]
            ]
            return (
                HTTPURLResponse(url: request.url!, statusCode: 422, httpVersion: nil, headerFields: nil)!,
                try JSONSerialization.data(withJSONObject: payload)
            )
        }

        _ = try await sdk?.activate(
            licenseKey: licenseKey,
            options: ActivationOptions(deviceId: "test-device")
        )
        sdk?.cache.setOfflineToken(try makeDummyOfflineToken(licenseKey: licenseKey))

        do {
            _ = try await sdk?.validate(licenseKey: licenseKey)
            XCTFail("Expected terminal server error")
        } catch let error as APIError {
            XCTAssertEqual(error.code, "license_suspended")
        }

        XCTAssertNil(sdk?.currentLicense())
        XCTAssertNil(sdk?.cache.getOfflineToken())
        if case .inactive = sdk?.getStatus() {
            // Expected.
        } else {
            XCTFail("Terminal server errors must purge all cached grants")
        }
    }

    func testTerminalErrorForDifferentLicenseDoesNotPurgeCurrentActivation() async throws {
        guard let sdk else { return XCTFail("SDK was not initialized") }
        let currentKey = "CURRENT-LICENSE"
        MockURLProtocol.requestHandler = { request in
            guard let url = request.url else { throw URLError(.badURL) }
            if url.path.contains("/activate") {
                let payload = self.makeActivationResponse(
                    licenseKey: currentKey,
                    deviceId: "test-device"
                )
                return (
                    HTTPURLResponse(url: url, statusCode: 201, httpVersion: nil, headerFields: nil)!,
                    try JSONSerialization.data(withJSONObject: payload)
                )
            }
            if url.path.contains("/offline_token") {
                let payload = [
                    "error": ["code": "forbidden", "message": "Offline scope unavailable"]
                ]
                return (
                    HTTPURLResponse(url: url, statusCode: 403, httpVersion: nil, headerFields: nil)!,
                    try JSONSerialization.data(withJSONObject: payload)
                )
            }

            let payload = [
                "error": ["code": "license_not_found", "message": "License not found"]
            ]
            return (
                HTTPURLResponse(url: url, statusCode: 404, httpVersion: nil, headerFields: nil)!,
                try JSONSerialization.data(withJSONObject: payload)
            )
        }

        _ = try await sdk.activate(
            licenseKey: currentKey,
            options: ActivationOptions(deviceId: "test-device")
        )

        do {
            _ = try await sdk.validate(licenseKey: "MISTYPED-LICENSE")
            XCTFail("Expected missing-license error")
        } catch let error as APIError {
            XCTAssertEqual(error.code, "license_not_found")
        }

        XCTAssertEqual(sdk.currentLicense()?.licenseKey, currentKey)
        if case .active = sdk.getStatus() {
            // The request did not concern the cached activation.
        } else {
            XCTFail("An unrelated validation must not purge the current activation")
        }
    }

    func testInvalidResponseForDifferentLicenseDoesNotStopCurrentSchedules() async throws {
        guard let sdk else { return XCTFail("SDK was not initialized") }
        let currentKey = "CURRENT-LICENSE"
        let otherKey = "OTHER-LICENSE"
        MockURLProtocol.requestHandler = { request in
            guard let url = request.url else { throw URLError(.badURL) }
            let payload: [String: Any]
            let status: Int

            if url.path.contains("/activate") {
                payload = self.makeActivationResponse(
                    licenseKey: currentKey,
                    deviceId: "test-device"
                )
                status = 201
            } else if url.path.contains("/validate") {
                payload = self.makeValidationResponse(valid: false, licenseKey: otherKey)
                status = 200
            } else {
                payload = ["error": ["code": "forbidden", "message": "Not available"]]
                status = 403
            }

            return (
                HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!,
                try JSONSerialization.data(withJSONObject: payload)
            )
        }

        _ = try await sdk.activate(
            licenseKey: currentKey,
            options: ActivationOptions(deviceId: "test-device")
        )
        let result = try await sdk.validate(licenseKey: otherKey)

        XCTAssertFalse(result.valid)
        XCTAssertEqual(sdk.currentLicense()?.licenseKey, currentKey)
        XCTAssertNotNil(sdk.validationTask)
        XCTAssertNotNil(sdk.heartbeatTask)
        XCTAssertNotNil(sdk.offlineRefreshTimer)
    }

    func testMismatchedDeactivationResponsePreservesCurrentGrant() async throws {
        guard let sdk else { return XCTFail("SDK was not initialized") }
        let licenseKey = "DEACTIVATION-CONTRACT"
        MockURLProtocol.requestHandler = { request in
            guard let url = request.url else { throw URLError(.badURL) }
            let payload: [String: Any]
            let status: Int

            if url.path.contains("/activate") {
                payload = self.makeActivationResponse(
                    licenseKey: licenseKey,
                    deviceId: "test-device"
                )
                status = 201
            } else if url.path.contains("/deactivate") {
                payload = [
                    "object": "deactivation",
                    "activation_id": "different-activation",
                    "deactivated_at": ISO8601DateFormatter().string(from: Date())
                ]
                status = 200
            } else {
                payload = ["error": ["code": "forbidden", "message": "Not available"]]
                status = 403
            }

            return (
                HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!,
                try JSONSerialization.data(withJSONObject: payload)
            )
        }

        _ = try await sdk.activate(
            licenseKey: licenseKey,
            options: ActivationOptions(deviceId: "test-device")
        )

        do {
            try await sdk.deactivate()
            XCTFail("Expected response identity rejection")
        } catch let error as LicenseSeatError {
            guard case .validationFailed = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }

        XCTAssertEqual(sdk.currentLicense()?.licenseKey, licenseKey)
    }

    func testMismatchedHeartbeatResponsePreservesCurrentGrant() async throws {
        guard let sdk else { return XCTFail("SDK was not initialized") }
        let licenseKey = "HEARTBEAT-CONTRACT"
        MockURLProtocol.requestHandler = { request in
            guard let url = request.url else { throw URLError(.badURL) }
            let payload: [String: Any]
            let status: Int

            if url.path.contains("/activate") {
                payload = self.makeActivationResponse(
                    licenseKey: licenseKey,
                    deviceId: "test-device"
                )
                status = 201
            } else if url.path.contains("/heartbeat") {
                let mismatchedActivation = self.makeActivationResponse(
                    licenseKey: "OTHER-LICENSE",
                    deviceId: "test-device"
                )
                payload = [
                    "object": "heartbeat",
                    "received_at": ISO8601DateFormatter().string(from: Date()),
                    "license": mismatchedActivation["license"] as Any
                ]
                status = 200
            } else {
                payload = ["error": ["code": "forbidden", "message": "Not available"]]
                status = 403
            }

            return (
                HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!,
                try JSONSerialization.data(withJSONObject: payload)
            )
        }

        _ = try await sdk.activate(
            licenseKey: licenseKey,
            options: ActivationOptions(deviceId: "test-device")
        )

        do {
            try await sdk.heartbeat()
            XCTFail("Expected response identity rejection")
        } catch let error as LicenseSeatError {
            guard case .validationFailed = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }

        XCTAssertEqual(sdk.currentLicense()?.licenseKey, licenseKey)
    }

    func testSuccessfulHeartbeatAdvancesProtectedClockWatermark() async throws {
        guard let sdk else { return XCTFail("SDK was not initialized") }
        await sdk.waitForInitialization()
        let licenseKey = "HEARTBEAT-WATERMARK"
        XCTAssertTrue(sdk.cache.setLicense(License(
            licenseKey: licenseKey,
            deviceId: "test-device",
            activationId: "heartbeat-activation",
            activatedAt: Date(),
            lastValidated: Date()
        )))
        XCTAssertNil(sdk.cache.getLastSeenTimestamp())

        MockURLProtocol.requestHandler = { request in
            guard let url = request.url else { throw URLError(.badURL) }
            let activation = self.makeActivationResponse(
                licenseKey: licenseKey,
                deviceId: "test-device"
            )
            let payload: [String: Any] = [
                "object": "heartbeat",
                "received_at": ISO8601DateFormatter().string(from: Date()),
                "license": activation["license"] as Any
            ]
            return (
                HTTPURLResponse(
                    url: url,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )!,
                try JSONSerialization.data(withJSONObject: payload)
            )
        }

        let requestStartedAt = Date().timeIntervalSince1970
        try await sdk.heartbeat()

        let watermark = try XCTUnwrap(sdk.cache.getLastSeenTimestamp())
        XCTAssertGreaterThanOrEqual(watermark, requestStartedAt)
    }

    func testLateOfflineErrorForOldActivationDoesNotPurgeSameKeyReplacement() async throws {
        let requestStarted = expectation(description: "old offline request started")
        let releaseResponse = DispatchSemaphore(value: 0)
        MockURLProtocol.requestHandler = { request in
            guard let url = request.url else { throw URLError(.badURL) }
            requestStarted.fulfill()
            _ = releaseResponse.wait(timeout: .now() + 2)
            let payload = [
                "error": ["code": "license_not_found", "message": "Old license missing"]
            ]
            return (
                HTTPURLResponse(url: url, statusCode: 404, httpVersion: nil, headerFields: nil)!,
                try JSONSerialization.data(withJSONObject: payload)
            )
        }

        let config = LicenseSeatConfig(
            apiBaseUrl: "https://api.test.com",
            productSlug: Self.testProductSlug,
            storagePrefix: "offline_race_test_\(UUID().uuidString)_",
            deviceIdentifier: "test-device",
            maxRetries: 0
        )
        let urlConfig = URLSessionConfiguration.ephemeral
        urlConfig.protocolClasses = [MockURLProtocol.self]
        let raceSDK = LicenseSeat(
            config: config,
            urlSession: URLSession(configuration: urlConfig)
        )
        defer { raceSDK.reset() }

        XCTAssertTrue(raceSDK.cache.setLicense(License(
            licenseKey: "OLD-LICENSE",
            deviceId: "test-device",
            activationId: "old-activation",
            activatedAt: Date(),
            lastValidated: Date()
        )))

        let syncTask = Task { await raceSDK.syncOfflineAssets() }
        await assertFulfillment(of: [requestStarted], timeout: 2)
        XCTAssertTrue(raceSDK.cache.setLicense(License(
            licenseKey: "OLD-LICENSE",
            deviceId: "test-device",
            activationId: "replacement-activation",
            activatedAt: Date(),
            lastValidated: Date()
        )))
        releaseResponse.signal()
        await syncTask.value

        XCTAssertEqual(raceSDK.currentLicense()?.licenseKey, "OLD-LICENSE")
        XCTAssertEqual(raceSDK.currentLicense()?.activationId, "replacement-activation")
    }

    func testOfflineFallbackCannotReturnGrantForDifferentLicense() async throws {
        guard let sdk else { return XCTFail("SDK was not initialized") }
        await sdk.waitForInitialization()
        try cacheValidOfflineGrant(on: sdk, licenseKey: "CACHED-LICENSE")
        MockURLProtocol.requestHandler = { _ in
            throw URLError(.notConnectedToInternet)
        }

        do {
            _ = try await sdk.validate(licenseKey: "REQUESTED-LICENSE")
            XCTFail("A cached grant for another license must never satisfy this request")
        } catch let error as URLError {
            XCTAssertEqual(error.code, .notConnectedToInternet)
        }

        XCTAssertEqual(sdk.currentLicense()?.licenseKey, "CACHED-LICENSE")
        XCTAssertNil(sdk.lastOfflineValidation)
    }

    func testOfflineFallbackCannotReturnGrantForDifferentDevice() async throws {
        guard let sdk else { return XCTFail("SDK was not initialized") }
        await sdk.waitForInitialization()
        try cacheValidOfflineGrant(on: sdk, licenseKey: "CACHED-LICENSE")
        MockURLProtocol.requestHandler = { _ in
            throw URLError(.notConnectedToInternet)
        }

        do {
            _ = try await sdk.validate(
                licenseKey: "CACHED-LICENSE",
                options: ValidationOptions(deviceId: "different-device")
            )
            XCTFail("A cached grant for another device must never satisfy this request")
        } catch let error as URLError {
            XCTAssertEqual(error.code, .notConnectedToInternet)
        }

        XCTAssertEqual(sdk.currentLicense()?.deviceId, "test-device")
        XCTAssertNil(sdk.lastOfflineValidation)
    }

    func testUnrelatedOnlineValidationPreservesCurrentOfflineStatus() async throws {
        guard let sdk else { return XCTFail("SDK was not initialized") }
        await sdk.waitForInitialization()
        try cacheValidOfflineGrant(on: sdk, licenseKey: "CACHED-LICENSE")
        let offlineResult = await sdk.verifyCachedOffline()
        XCTAssertTrue(offlineResult.valid)
        sdk.lastOfflineValidation = offlineResult

        MockURLProtocol.requestHandler = { request in
            let payload = self.makeValidationResponse(
                valid: true,
                licenseKey: "OTHER-LICENSE"
            )
            return (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )!,
                try JSONSerialization.data(withJSONObject: payload)
            )
        }

        let result = try await sdk.validate(licenseKey: "OTHER-LICENSE")

        XCTAssertTrue(result.valid)
        XCTAssertEqual(sdk.currentLicense()?.licenseKey, "CACHED-LICENSE")
        if case .offlineValid(let details) = sdk.getStatus() {
            XCTAssertEqual(details.license, "CACHED-LICENSE")
        } else {
            XCTFail("Validating another key must not relabel the cached grant as online")
        }
    }

    func testResetSupersedesInFlightActivation() async throws {
        guard let sdk else { return XCTFail("SDK was not initialized") }
        await sdk.waitForInitialization()
        let requestStarted = expectation(description: "activation request started")
        let releaseResponse = DispatchSemaphore(value: 0)
        MockURLProtocol.requestHandler = { request in
            requestStarted.fulfill()
            _ = releaseResponse.wait(timeout: .now() + 2)
            let payload = self.makeActivationResponse(
                licenseKey: "STALE-ACTIVATION",
                deviceId: "test-device"
            )
            return (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 201,
                    httpVersion: nil,
                    headerFields: nil
                )!,
                try JSONSerialization.data(withJSONObject: payload)
            )
        }

        let activationTask = Task {
            try await sdk.activate(
                licenseKey: "STALE-ACTIVATION",
                options: ActivationOptions(deviceId: "test-device")
            )
        }
        await assertFulfillment(of: [requestStarted], timeout: 2)
        sdk.reset()
        releaseResponse.signal()

        do {
            _ = try await activationTask.value
            XCTFail("A response superseded by reset must not restore a license")
        } catch let error as LicenseSeatError {
            guard case .activationFailed = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        XCTAssertNil(sdk.currentLicense())
    }

    func testSuccessfulActivationClearsStaleOfflineDecisionAndGrant() async throws {
        guard let sdk else { return XCTFail("SDK was not initialized") }
        await sdk.waitForInitialization()
        let licenseKey = "REACTIVATED-LICENSE"
        let invalidData = try JSONSerialization.data(
            withJSONObject: makeValidationResponse(valid: false, licenseKey: licenseKey)
        )
        sdk.lastOfflineValidation = try JSONDecoder().decode(
            ValidationResponse.self,
            from: invalidData
        )
        XCTAssertTrue(sdk.cache.setOfflineToken(try makeDummyOfflineToken(licenseKey: licenseKey)))

        MockURLProtocol.requestHandler = { request in
            let payload = self.makeActivationResponse(
                licenseKey: licenseKey,
                deviceId: "test-device"
            )
            return (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 201,
                    httpVersion: nil,
                    headerFields: nil
                )!,
                try JSONSerialization.data(withJSONObject: payload)
            )
        }

        _ = try await sdk.activate(
            licenseKey: licenseKey,
            options: ActivationOptions(deviceId: "test-device")
        )

        XCTAssertNil(sdk.lastOfflineValidation)
        XCTAssertNil(sdk.cache.getOfflineToken())
        guard case .active = sdk.getStatus() else {
            return XCTFail("Authoritative activation must replace stale offline-invalid state")
        }
    }

    func testNewerActivationSupersedesOlderInFlightResponse() async throws {
        guard let sdk else { return XCTFail("SDK was not initialized") }
        await sdk.waitForInitialization()
        let oldRequestStarted = expectation(description: "old activation request started")
        let releaseOldResponse = DispatchSemaphore(value: 0)
        MockURLProtocol.requestHandler = { request in
            guard let url = request.url else { throw URLError(.badURL) }
            let licenseKey: String
            if url.path.contains("/licenses/OLD-ACTIVATION/activate") {
                oldRequestStarted.fulfill()
                _ = releaseOldResponse.wait(timeout: .now() + 0.5)
                licenseKey = "OLD-ACTIVATION"
            } else if url.path.contains("/licenses/NEW-ACTIVATION/activate") {
                licenseKey = "NEW-ACTIVATION"
            } else {
                throw URLError(.notConnectedToInternet)
            }
            let payload = self.makeActivationResponse(
                licenseKey: licenseKey,
                deviceId: "test-device"
            )
            return (
                HTTPURLResponse(
                    url: url,
                    statusCode: 201,
                    httpVersion: nil,
                    headerFields: nil
                )!,
                try JSONSerialization.data(withJSONObject: payload)
            )
        }

        let oldActivationTask = Task {
            try await sdk.activate(
                licenseKey: "OLD-ACTIVATION",
                options: ActivationOptions(deviceId: "test-device")
            )
        }
        await assertFulfillment(of: [oldRequestStarted], timeout: 2)
        let newLicense = try await sdk.activate(
            licenseKey: "NEW-ACTIVATION",
            options: ActivationOptions(deviceId: "test-device")
        )
        releaseOldResponse.signal()

        do {
            _ = try await oldActivationTask.value
            XCTFail("The older response must not replace the newer activation")
        } catch let error as LicenseSeatError {
            guard case .activationFailed = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        XCTAssertEqual(newLicense.licenseKey, "NEW-ACTIVATION")
        XCTAssertEqual(sdk.currentLicense()?.licenseKey, "NEW-ACTIVATION")
    }

    func testLateDeactivationSuccessCannotClearReplacementActivation() async throws {
        guard let sdk else { return XCTFail("SDK was not initialized") }
        await sdk.waitForInitialization()
        XCTAssertTrue(sdk.cache.setLicense(License(
            licenseKey: "SHARED-LICENSE",
            deviceId: "test-device",
            activationId: "act-12345-uuid",
            activatedAt: Date(),
            lastValidated: Date()
        )))
        let requestStarted = expectation(description: "deactivation request started")
        let releaseResponse = DispatchSemaphore(value: 0)
        MockURLProtocol.requestHandler = { request in
            requestStarted.fulfill()
            _ = releaseResponse.wait(timeout: .now() + 2)
            return (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )!,
                try JSONSerialization.data(withJSONObject: self.makeDeactivationResponse())
            )
        }

        let deactivationTask = Task { try await sdk.deactivate() }
        await assertFulfillment(of: [requestStarted], timeout: 2)
        XCTAssertTrue(sdk.cache.setLicense(License(
            licenseKey: "SHARED-LICENSE",
            deviceId: "test-device",
            activationId: "replacement-activation",
            activatedAt: Date(),
            lastValidated: Date()
        )))
        releaseResponse.signal()
        try await deactivationTask.value

        XCTAssertEqual(sdk.currentLicense()?.licenseKey, "SHARED-LICENSE")
        XCTAssertEqual(sdk.currentLicense()?.activationId, "replacement-activation")
    }

    func testUnrelatedNotFoundDoesNotMasqueradeAsSuccessfulDeactivation() async throws {
        guard let sdk else { return XCTFail("SDK was not initialized") }
        await sdk.waitForInitialization()
        XCTAssertTrue(sdk.cache.setLicense(License(
            licenseKey: "PRESERVED-LICENSE",
            deviceId: "test-device",
            activationId: "act-12345-uuid",
            activatedAt: Date(),
            lastValidated: Date()
        )))
        MockURLProtocol.requestHandler = { request in
            let payload = [
                "error": ["code": "product_not_found", "message": "Product not found"]
            ]
            return (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 404,
                    httpVersion: nil,
                    headerFields: nil
                )!,
                try JSONSerialization.data(withJSONObject: payload)
            )
        }

        do {
            try await sdk.deactivate()
            XCTFail("A non-activation 404 must not be treated as idempotent deactivation")
        } catch let error as APIError {
            XCTAssertEqual(error.code, "product_not_found")
        }
        XCTAssertEqual(sdk.currentLicense()?.licenseKey, "PRESERVED-LICENSE")
    }

    func testGenericNotFoundDoesNotMasqueradeAsSuccessfulDeactivation() async throws {
        guard let sdk else { return XCTFail("SDK was not initialized") }
        await sdk.waitForInitialization()
        XCTAssertTrue(sdk.cache.setLicense(License(
            licenseKey: "PRESERVED-LICENSE",
            deviceId: "test-device",
            activationId: "act-12345-uuid",
            activatedAt: Date(),
            lastValidated: Date()
        )))
        MockURLProtocol.requestHandler = { request in
            let payload = [
                "error": ["code": "not_found", "message": "Resource not found"]
            ]
            return (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 404,
                    httpVersion: nil,
                    headerFields: nil
                )!,
                try JSONSerialization.data(withJSONObject: payload)
            )
        }

        do {
            try await sdk.deactivate()
            XCTFail("A generic 404 must not be treated as idempotent deactivation")
        } catch let error as APIError {
            XCTAssertEqual(error.code, "not_found")
        }
        XCTAssertEqual(sdk.currentLicense()?.licenseKey, "PRESERVED-LICENSE")
    }

    func testLateTerminalValidationCannotPurgeSameKeyReplacement() async throws {
        guard let sdk else { return XCTFail("SDK was not initialized") }
        await sdk.waitForInitialization()
        try cacheValidOfflineGrant(
            on: sdk,
            licenseKey: "SHARED-LICENSE",
            activationId: "old-activation"
        )
        let requestStarted = expectation(description: "validation request started")
        let releaseResponse = DispatchSemaphore(value: 0)
        MockURLProtocol.requestHandler = { request in
            requestStarted.fulfill()
            _ = releaseResponse.wait(timeout: .now() + 2)
            let payload = [
                "error": ["code": "license_suspended", "message": "License suspended"]
            ]
            return (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 422,
                    httpVersion: nil,
                    headerFields: nil
                )!,
                try JSONSerialization.data(withJSONObject: payload)
            )
        }

        let validationTask = Task {
            try await sdk.validate(licenseKey: "SHARED-LICENSE")
        }
        await assertFulfillment(of: [requestStarted], timeout: 2)
        try cacheValidOfflineGrant(
            on: sdk,
            licenseKey: "SHARED-LICENSE",
            activationId: "replacement-activation"
        )
        releaseResponse.signal()

        do {
            _ = try await validationTask.value
            XCTFail("Expected the terminal API response")
        } catch let error as APIError {
            XCTAssertEqual(error.code, "license_suspended")
        }
        XCTAssertEqual(sdk.currentLicense()?.activationId, "replacement-activation")
        XCTAssertNotNil(sdk.cache.getOfflineToken())
    }

    func testLateInvalidValidationCannotMutateSameDeviceReplacement() async throws {
        guard let sdk else { return XCTFail("SDK was not initialized") }
        await sdk.waitForInitialization()
        try cacheValidOfflineGrant(
            on: sdk,
            licenseKey: "SHARED-LICENSE",
            activationId: "old-activation"
        )
        let requestStarted = expectation(description: "validation request started")
        let releaseResponse = DispatchSemaphore(value: 0)
        MockURLProtocol.requestHandler = { request in
            requestStarted.fulfill()
            _ = releaseResponse.wait(timeout: .now() + 2)
            let payload = self.makeValidationResponse(
                valid: false,
                licenseKey: "SHARED-LICENSE"
            )
            return (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )!,
                try JSONSerialization.data(withJSONObject: payload)
            )
        }

        let validationTask = Task {
            try await sdk.validate(licenseKey: "SHARED-LICENSE")
        }
        await assertFulfillment(of: [requestStarted], timeout: 2)
        try cacheValidOfflineGrant(
            on: sdk,
            licenseKey: "SHARED-LICENSE",
            activationId: "replacement-activation"
        )
        releaseResponse.signal()

        let staleResult = try await validationTask.value
        XCTAssertFalse(staleResult.valid)
        XCTAssertEqual(sdk.currentLicense()?.activationId, "replacement-activation")
        XCTAssertEqual(sdk.currentLicense()?.validation?.valid, true)
        XCTAssertNotNil(sdk.cache.getOfflineToken())
    }

    func testTransportFailureCannotFallbackToSameKeyReplacementActivation() async throws {
        guard let sdk else { return XCTFail("SDK was not initialized") }
        await sdk.waitForInitialization()
        try cacheValidOfflineGrant(
            on: sdk,
            licenseKey: "SHARED-LICENSE",
            activationId: "old-activation"
        )
        let requestStarted = expectation(description: "validation request started")
        let releaseResponse = DispatchSemaphore(value: 0)
        MockURLProtocol.requestHandler = { _ in
            requestStarted.fulfill()
            _ = releaseResponse.wait(timeout: .now() + 2)
            throw URLError(.notConnectedToInternet)
        }

        let validationTask = Task {
            try await sdk.validate(licenseKey: "SHARED-LICENSE")
        }
        await assertFulfillment(of: [requestStarted], timeout: 2)
        try cacheValidOfflineGrant(
            on: sdk,
            licenseKey: "SHARED-LICENSE",
            activationId: "replacement-activation"
        )
        releaseResponse.signal()

        do {
            _ = try await validationTask.value
            XCTFail("A stale request must not consume a replacement activation's offline grant")
        } catch let error as URLError {
            XCTAssertEqual(error.code, .notConnectedToInternet)
        }
        XCTAssertEqual(sdk.currentLicense()?.activationId, "replacement-activation")
        XCTAssertNil(sdk.lastOfflineValidation)
    }

    func testOfflineInvalidDecisionDeniesPreviouslyCachedEntitlements() throws {
        guard let sdk else { return XCTFail("SDK was not initialized") }
        let licenseKey = "ENTITLEMENT-OFFLINE-INVALID"
        var validPayload = makeValidationResponse(valid: true, licenseKey: licenseKey)
        var licensePayload = try XCTUnwrap(validPayload["license"] as? [String: Any])
        licensePayload["active_entitlements"] = [[
            "key": "premium", "expires_at": NSNull(), "metadata": NSNull()
        ]]
        validPayload["license"] = licensePayload
        let validData = try JSONSerialization.data(withJSONObject: validPayload)
        let validResult = try JSONDecoder().decode(ValidationResponse.self, from: validData)
        XCTAssertTrue(sdk.cache.setLicense(License(
            licenseKey: licenseKey,
            deviceId: "test-device",
            activationId: "cached-activation",
            activatedAt: Date(),
            lastValidated: Date(),
            validation: validResult
        )))
        XCTAssertTrue(sdk.checkEntitlement("premium").active)

        let invalidData = try JSONSerialization.data(
            withJSONObject: makeValidationResponse(valid: false, licenseKey: licenseKey)
        )
        sdk.lastOfflineValidation = try JSONDecoder().decode(
            ValidationResponse.self,
            from: invalidData
        )

        let entitlement = sdk.checkEntitlement("premium")
        XCTAssertFalse(entitlement.active)
        XCTAssertEqual(entitlement.reason, .noLicense)
    }

    func testSigningKeyContractRejectsMalformedOrInactiveKeysWithoutCaching() async throws {
        guard let sdk else { return XCTFail("SDK was not initialized") }
        await sdk.waitForInitialization()
        let keyId = "expected-key"
        let validKey = Base64URL.encode(Data(repeating: 7, count: 32))
        let invalidResponses: [[String: Any]] = [
            [
                "object": "not_a_signing_key", "key_id": keyId,
                "algorithm": "Ed25519", "public_key": validKey, "status": "active"
            ],
            [
                "object": "signing_key", "key_id": "different-key",
                "algorithm": "Ed25519", "public_key": validKey, "status": "active"
            ],
            [
                "object": "signing_key", "key_id": keyId,
                "algorithm": "RSA", "public_key": validKey, "status": "active"
            ],
            [
                "object": "signing_key", "key_id": keyId,
                "algorithm": "Ed25519", "public_key": validKey, "status": "retired"
            ],
            [
                "object": "signing_key", "key_id": keyId,
                "algorithm": "Ed25519",
                "public_key": Base64URL.encode(Data(repeating: 7, count: 31)),
                "status": "active"
            ],
            [
                "object": "signing_key", "key_id": keyId,
                "algorithm": "Ed25519", "public_key": "not base64", "status": "active"
            ]
        ]

        for payload in invalidResponses {
            MockURLProtocol.requestHandler = { request in
                return (
                    HTTPURLResponse(
                        url: request.url!,
                        statusCode: 200,
                        httpVersion: nil,
                        headerFields: nil
                    )!,
                    try JSONSerialization.data(withJSONObject: payload)
                )
            }

            do {
                _ = try await sdk.getSigningKey(keyId: keyId)
                XCTFail("Malformed signing-key response should be rejected: \(payload)")
            } catch let error as LicenseSeatError {
                XCTAssertEqual(error, .invalidPublicKey)
            }
        }

        sdk.cache.clear()
        try cacheValidOfflineGrant(
            on: sdk,
            licenseKey: "CACHED-LICENSE",
            cachePublicKey: false
        )
        MockURLProtocol.requestHandler = { request in
            let payload: [String: Any] = [
                "object": "signing_key",
                "key_id": "offline-key-CACHED-LICENSE",
                "algorithm": "Ed25519",
                "public_key": Base64URL.encode(Data(repeating: 7, count: 31)),
                "status": "active"
            ]
            return (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )!,
                try JSONSerialization.data(withJSONObject: payload)
            )
        }

        let result = await sdk.verifyCachedOffline()

        XCTAssertFalse(result.valid)
        XCTAssertEqual(result.code, "no_public_key")
        XCTAssertNil(sdk.cache.getPublicKey("offline-key-CACHED-LICENSE"))
    }

    func testCachedOfflineVerificationRepairsCorruptedSigningKeys() async throws {
        guard let sdk else { return XCTFail("SDK was not initialized") }
        await sdk.waitForInitialization()
        let corruptKeys = [
            "not-base64",
            Base64URL.encode(Data(repeating: 0xA5, count: 32))
        ]

        for (index, corruptKey) in corruptKeys.enumerated() {
            sdk.cache.clear()
            let licenseKey = "CORRUPT-CACHE-\(index)"
            let grant = try cacheValidOfflineGrant(on: sdk, licenseKey: licenseKey)
            let keyId = grant.offlineToken.token.kid
            let authoritativeKey = Base64URL.encode(
                grant.privateKey.publicKey.rawRepresentation
            )
            XCTAssertTrue(sdk.cache.setPublicKey(keyId, corruptKey))
            var signingKeyRequests = 0

            MockURLProtocol.requestHandler = { request in
                signingKeyRequests += 1
                let payload: [String: Any] = [
                    "object": "signing_key",
                    "key_id": keyId,
                    "algorithm": "Ed25519",
                    "public_key": authoritativeKey,
                    "status": "active"
                ]
                return (
                    HTTPURLResponse(
                        url: request.url!,
                        statusCode: 200,
                        httpVersion: nil,
                        headerFields: nil
                    )!,
                    try JSONSerialization.data(withJSONObject: payload)
                )
            }

            let result = await sdk.verifyCachedOffline()

            XCTAssertTrue(result.valid)
            XCTAssertEqual(signingKeyRequests, 1)
            XCTAssertEqual(sdk.cache.getPublicKey(keyId), authoritativeKey)
        }
    }

    func testOfflineAssetSyncRepairsValidLengthWrongCachedSigningKey() async throws {
        guard let sdk else { return XCTFail("SDK was not initialized") }
        await sdk.waitForInitialization()
        let grant = try cacheValidOfflineGrant(on: sdk, licenseKey: "SYNC-KEY-RECOVERY")
        let keyId = grant.offlineToken.token.kid
        let authoritativeKey = Base64URL.encode(grant.privateKey.publicKey.rawRepresentation)
        XCTAssertTrue(sdk.cache.setPublicKey(
            keyId,
            Base64URL.encode(Data(repeating: 0x5A, count: 32))
        ))
        var offlineTokenRequests = 0
        var signingKeyRequests = 0

        MockURLProtocol.requestHandler = { request in
            guard let url = request.url else { throw URLError(.badURL) }
            if url.path.contains("/offline_token") {
                offlineTokenRequests += 1
                return (
                    HTTPURLResponse(
                        url: url,
                        statusCode: 200,
                        httpVersion: nil,
                        headerFields: nil
                    )!,
                    try JSONEncoder().encode(grant.offlineToken)
                )
            }

            signingKeyRequests += 1
            let payload: [String: Any] = [
                "object": "signing_key",
                "key_id": keyId,
                "algorithm": "Ed25519",
                "public_key": authoritativeKey,
                "status": "active"
            ]
            return (
                HTTPURLResponse(
                    url: url,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )!,
                try JSONSerialization.data(withJSONObject: payload)
            )
        }

        await sdk.syncOfflineAssets()

        XCTAssertEqual(offlineTokenRequests, 1)
        XCTAssertEqual(signingKeyRequests, 1)
        XCTAssertEqual(sdk.cache.getPublicKey(keyId), authoritativeKey)
        XCTAssertEqual(sdk.cache.getOfflineToken(), grant.offlineToken)
        let cachedResult = await sdk.verifyCachedOffline()
        XCTAssertTrue(cachedResult.valid)
    }

    func testHeartbeatWithoutActiveLicenseFailsExplicitly() async {
        guard let sdk else { return XCTFail("SDK was not initialized") }
        sdk.cache.clear()

        do {
            try await sdk.heartbeat()
            XCTFail("Expected noActiveLicense")
        } catch let error as LicenseSeatError {
            XCTAssertEqual(error, .noActiveLicense)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testInitializationDoesNotStartFallbackPollingWhileOnline() async {
        guard let sdk else { return XCTFail("SDK was not initialized") }

        await sdk.waitForInitialization()

        XCTAssertTrue(sdk.isOnline)
        XCTAssertNil(sdk.connectivityTimer)
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

    func testActivationRejectsMismatchedServerIdentity() async {
        MockURLProtocol.requestHandler = { request in
            guard let url = request.url else { throw URLError(.badURL) }
            let payload = self.makeActivationResponse(
                licenseKey: "DIFFERENT-LICENSE",
                deviceId: "test-device"
            )
            let data = try JSONSerialization.data(withJSONObject: payload)
            return (
                HTTPURLResponse(
                    url: url,
                    statusCode: 201,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!,
                data
            )
        }

        do {
            _ = try await sdk?.activate(
                licenseKey: "REQUESTED-LICENSE",
                options: ActivationOptions(deviceId: "test-device")
            )
            XCTFail("Expected mismatched activation response to be rejected")
        } catch let error as LicenseSeatError {
            guard case .activationFailed = error else {
                return XCTFail("Unexpected LicenseSeat error: \(error)")
            }
            XCTAssertNil(sdk?.currentLicense())
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    func testValidationRejectsMismatchedServerIdentityWithoutReplacingCachedClaims() async throws {
        let requestedKey = "REQUESTED-LICENSE"
        MockURLProtocol.requestHandler = { request in
            guard let url = request.url else { throw URLError(.badURL) }
            let payload: [String: Any]
            let status: Int
            if url.path.contains("/activate") {
                payload = self.makeActivationResponse(
                    licenseKey: requestedKey,
                    deviceId: "test-device"
                )
                status = 201
            } else {
                payload = self.makeValidationResponse(
                    valid: true,
                    licenseKey: "DIFFERENT-LICENSE"
                )
                status = 200
            }
            let data = try JSONSerialization.data(withJSONObject: payload)
            return (
                HTTPURLResponse(
                    url: url,
                    statusCode: status,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!,
                data
            )
        }

        _ = try await sdk?.activate(
            licenseKey: requestedKey,
            options: ActivationOptions(deviceId: "test-device")
        )

        do {
            _ = try await sdk?.validate(licenseKey: requestedKey)
            XCTFail("Expected mismatched validation response to be rejected")
        } catch let error as LicenseSeatError {
            guard case .validationFailed = error else {
                return XCTFail("Unexpected LicenseSeat error: \(error)")
            }
            XCTAssertEqual(sdk?.currentLicense()?.validation?.license.key, requestedKey)
        }
    }
}
