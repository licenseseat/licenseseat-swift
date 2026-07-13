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
#if canImport(SwiftUI)
import SwiftUI
#endif

@MainActor
final class LicenseSeatStoreTests: LicenseSeatTestCase {
    private var store: LicenseSeatStore!
    private var cancellables: Set<AnyCancellable> = []

    nonisolated private static let testProductSlug = "test-app"

    override func setUp() async throws {
        // Register the mock protocol globally so default URLSessions pick it up.
        _ = URLProtocol.registerClass(MockURLProtocol.self)
        MockURLProtocol.reset()

        // Customise config with auto-validation disabled by default to prevent noise
        let config = LicenseSeatConfig(
            apiBaseUrl: "https://api.test.com",
            apiKey: "test_key",
            productSlug: Self.testProductSlug,
            storagePrefix: "store_test_\(UUID().uuidString)_",
            deviceIdentifier: "test-device",
            autoValidateInterval: 0, // Disable auto-validation by default
            debug: false
        )

        // Create a URLSession that uses the mock protocol.
        let conf = URLSessionConfiguration.ephemeral
        conf.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: conf)

        // Use a detached store instance so tests don't affect the global singleton.
        store = LicenseSeatStore(config: config, urlSession: session)
    }

    override func tearDown() {
        MainActor.assumeIsolated {
            // Stop any running auto-validation
            store?.seat?.reset()
            LicenseSeatStore.shared.seat?.reset()
            store = nil

            URLProtocol.unregisterClass(MockURLProtocol.self)
            cancellables.removeAll()
        }
        super.tearDown()
    }

    // MARK: – Helpers

    /// Stubs network endpoints required for activation & validation.
    private func installStubHandlers() {
        let signingKey = Curve25519.Signing.PrivateKey()

        MockURLProtocol.requestHandler = { request in
            let path = request.url!.path
            let headers = ["Content-Type": "application/json"]

            // Echo the requested license identity exactly as the real API does.
            let pathComponents = request.url!.pathComponents
            let licenseKey = pathComponents.firstIndex(of: "licenses")
                .flatMap { index in
                    pathComponents.indices.contains(index + 1) ? pathComponents[index + 1] : nil
                }
                ?? "LICENSE-TEST"

            if path.contains("/activate") {
                // Return v1 ActivationResponse
                let payload: [String: Any] = [
                    "object": "activation",
                    "id": "act-12345-uuid",
                    "fingerprint": "test-device",
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
                let data = try JSONSerialization.data(withJSONObject: payload)
                let resp = HTTPURLResponse(url: request.url!, statusCode: 201, httpVersion: nil, headerFields: headers)!
                return (resp, data)
            } else if path.contains("/validate") {
                // Return v1 ValidationResponse
                let result: [String: Any] = [
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
                        "active_entitlements": [],
                        "metadata": NSNull(),
                        "product": ["slug": Self.testProductSlug, "name": "Test App"]
                    ],
                    "activation": NSNull()
                ]
                let data = try JSONSerialization.data(withJSONObject: result)
                let resp = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: headers)!
                return (resp, data)
            } else if path.contains("/deactivate") {
                // Return v1 DeactivationResponse
                let result: [String: Any] = [
                    "object": "deactivation",
                    "activation_id": "act-12345-uuid",
                    "deactivated_at": ISO8601DateFormatter().string(from: Date())
                ]
                let data = try JSONSerialization.data(withJSONObject: result)
                let resp = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: headers)!
                return (resp, data)
            } else if path.contains("/offline_token") {
                // Return a cryptographically valid v1 OfflineTokenResponse so
                // background asset sync exercises the real verification path.
                let now = Int(Date().timeIntervalSince1970)
                let token: [String: Any] = [
                    "schema_version": 1,
                    "license_key": licenseKey,
                    "product_slug": Self.testProductSlug,
                    "plan_key": "pro",
                    "mode": "hardware_locked",
                    "seat_limit": 5,
                    "fingerprint": "test-device",
                    "iat": now,
                    "exp": now + 86400 * 30,
                    "nbf": now,
                    "kid": "test-key-id",
                    "entitlements": []
                ]
                let canonical = try CanonicalJSON.stringify(token)
                let signature = try signingKey.signature(for: Data(canonical.utf8))
                let offlineToken: [String: Any] = [
                    "object": "offline_token",
                    "token": token,
                    "signature": [
                        "algorithm": "Ed25519",
                        "key_id": "test-key-id",
                        "value": Base64URL.encode(signature)
                    ],
                    "canonical": canonical
                ]
                let data = try JSONSerialization.data(withJSONObject: offlineToken)
                let resp = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: headers)!
                return (resp, data)
            } else if path.contains("/signing_keys/") {
                // Return v1 SigningKeyResponse
                let publicKey: [String: Any] = [
                    "object": "signing_key",
                    "key_id": "test-key-id",
                    "algorithm": "Ed25519",
                    "public_key": Base64URL.encode(signingKey.publicKey.rawRepresentation),
                    "status": "active"
                ]
                let data = try JSONSerialization.data(withJSONObject: publicKey)
                let resp = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: headers)!
                return (resp, data)
            } else {
                // For any other path, return a 404
                let resp = HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: headers)!
                return (resp, Data())
            }
        }
    }

    // MARK: – Tests

    #if canImport(Combine)
    func testNextAutoValidationAtPropagation() async throws {
        // Create a new store with auto-validation enabled for this specific test
        let interval: TimeInterval = 0.2
        let config = LicenseSeatConfig(
            apiBaseUrl: "https://api.test.com",
            apiKey: "test_key",
            productSlug: Self.testProductSlug,
            storagePrefix: "store_test_\(UUID().uuidString)_",
            deviceIdentifier: "test-device",
            autoValidateInterval: interval,
            debug: false
        )
        
        let conf = URLSessionConfiguration.ephemeral
        conf.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: conf)
        
        store = LicenseSeatStore(config: config, urlSession: session)
        installStubHandlers()

        // Expectation for published nextAutoValidationAt
        let exp = expectation(description: "nextAutoValidationAt set")

        store.$nextAutoValidationAt
            .dropFirst() // Ignore initial nil
            .sink { date in
                if date != nil {
                    exp.fulfill()
                }
            }
            .store(in: &cancellables)

        // Trigger activation (which schedules auto-validation)
        _ = try await store.activate("LICENSE-TEST-123")

        await assertFulfillment(of: [exp], timeout: 2.0)

        guard let nextRun = store.nextAutoValidationAt else {
            XCTFail("nextAutoValidationAt should not be nil after activation")
            return
        }

        // The next run should be roughly interval seconds in the future.
        let delta = nextRun.timeIntervalSinceNow
        XCTAssertGreaterThan(delta, 0)
        XCTAssertLessThanOrEqual(delta, interval + 0.3) // Allow some scheduling slop
    }
    #endif

    #if canImport(SwiftUI)
    func testLicenseStatePropertyWrapper() async throws {
        installStubHandlers()

        // Configure the shared store with the same mocked session so the property wrapper observes it.
        let conf = URLSessionConfiguration.ephemeral
        conf.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: conf)
        LicenseSeatStore.shared.configure(
            apiKey: "test_key",
            apiBaseURL: URL(string: "https://api.test.com")!,
            force: true,
            urlSession: session
        ) { cfg in
            cfg.productSlug = Self.testProductSlug
            cfg.deviceIdentifier = "test-device"
            cfg.autoValidateInterval = 0 // Disable auto-validation
            cfg.debug = false
            cfg.storagePrefix = "store_test_\(UUID().uuidString)_"
        }

        _ = try await LicenseSeatStore.shared.activate("LICENSE-TEST-456")

        struct WrapperView: View {
            @LicenseState var status
            var body: some View { EmptyView() }
        }

        let view = WrapperView()
        switch view.status {
        case .active, .offlineValid:
            // success
            break
        default:
            XCTFail("Expected status to be active after activation")
        }
    }
    #endif
    
    func testEntitlementWithNoLicense() async throws {
        let config = LicenseSeatConfig(storagePrefix: "store_empty_\(UUID().uuidString)_")
        let unconfiguredStore = LicenseSeatStore(config: config)
        unconfiguredStore.seat?.reset()
        let status = unconfiguredStore.entitlement("test-feature")
        
        XCTAssertFalse(status.active)
        XCTAssertEqual(status.reason, .noLicense)
        XCTAssertNil(status.expiresAt)
        XCTAssertNil(status.entitlement)
    }
    
    func testConfigureWithCustomOptions() async {
        let testURL = URL(string: "https://custom.api.com")!
        store.configure(
            apiKey: "custom_key",
            apiBaseURL: testURL,
            force: true,
            urlSession: nil,
            options: { config in
                config.productSlug = Self.testProductSlug
                config.debug = false
                config.autoValidateInterval = 7200
                config.maxOfflineDays = 14
            }
        )
        
        // Verify configuration took effect by checking if seat exists
        XCTAssertNotNil(store.seat)
        XCTAssertEqual(store.seat?.config.productSlug, Self.testProductSlug)
    }

    func testStaticAndSwiftUIConfigurationShareOneCanonicalInstance() async {
        let prefix = "canonical_static_\(UUID().uuidString)_"
        LicenseSeat.configure(
            apiKey: "static-key",
            productSlug: Self.testProductSlug,
            force: true
        ) { config in
            config.storagePrefix = prefix
            config.autoValidateInterval = 0
            config.heartbeatInterval = 0
        }

        XCTAssertTrue(LicenseSeatStore.shared.seat === LicenseSeat.shared)
        XCTAssertEqual(LicenseSeatStore.shared.seat?.config.productSlug, Self.testProductSlug)
        XCTAssertEqual(LicenseSeat.shared.config.storagePrefix, prefix)
    }

    func testSharedStoreConfigurationInstallsCanonicalStaticInstance() async {
        let prefix = "canonical_store_\(UUID().uuidString)_"
        LicenseSeatStore.shared.configure(
            apiKey: "store-key",
            productSlug: Self.testProductSlug,
            force: true
        ) { config in
            config.storagePrefix = prefix
            config.autoValidateInterval = 0
            config.heartbeatInterval = 0
        }

        XCTAssertTrue(LicenseSeatStore.shared.seat === LicenseSeat.shared)
        XCTAssertEqual(LicenseSeat.shared.config.apiKey, "store-key")
        XCTAssertEqual(LicenseSeat.shared.config.storagePrefix, prefix)
    }

    func testDetachedStoreConfigurationDoesNotReplaceCanonicalStaticInstance() async {
        let canonical = LicenseSeat.shared

        store.configure(
            apiKey: "detached-key",
            productSlug: Self.testProductSlug,
            force: true
        ) { config in
            config.storagePrefix = "detached_\(UUID().uuidString)_"
        }

        XCTAssertTrue(LicenseSeat.shared === canonical)
        XCTAssertFalse(store.seat === canonical)
    }
    
    func testForceReconfiguration() async {
        // First config
        store.configure(apiKey: "key1", urlSession: URLSession.shared)
        let firstSeat = store.seat
        
        // Second config without force - should be ignored
        store.configure(apiKey: "key2", urlSession: URLSession.shared)
        XCTAssertTrue(store.seat === firstSeat)
        
        // Third config with force - should create new seat
        store.configure(apiKey: "key3", force: true, urlSession: URLSession.shared)
        XCTAssertFalse(store.seat === firstSeat)
    }

    func testForceReconfigurationShutsDownReplacedInstance() async throws {
        let lifecycleConfig = LicenseSeatConfig(
            apiBaseUrl: "https://api.test.com",
            apiKey: "first-key",
            productSlug: Self.testProductSlug,
            storagePrefix: "force_lifecycle_test_\(UUID().uuidString)_",
            autoValidateInterval: 60,
            heartbeatInterval: 60,
            offlineTokenRefreshInterval: 60
        )
        let lifecycleStore = LicenseSeatStore(config: lifecycleConfig)
        let firstSeat = try XCTUnwrap(lifecycleStore.seat)
        firstSeat.startAutoValidation(licenseKey: "FIRST-LICENSE")
        firstSeat.startHeartbeat()
        firstSeat.scheduleOfflineRefresh()

        XCTAssertNotNil(firstSeat.validationTask)
        XCTAssertNotNil(firstSeat.heartbeatTask)
        XCTAssertNotNil(firstSeat.offlineRefreshTimer)
        XCTAssertNotNil(firstSeat.apiClient.onNetworkStatusChange)

        lifecycleStore.configure(
            apiKey: "replacement-key",
            productSlug: Self.testProductSlug,
            force: true
        )

        XCTAssertFalse(lifecycleStore.seat === firstSeat)
        XCTAssertNil(firstSeat.initializationTask)
        XCTAssertNil(firstSeat.backgroundValidationTask)
        XCTAssertNil(firstSeat.offlineSyncTask)
        XCTAssertNil(firstSeat.validationTask)
        XCTAssertNil(firstSeat.heartbeatTask)
        XCTAssertNil(firstSeat.offlineRefreshTimer)
        XCTAssertNil(firstSeat.apiClient.onNetworkStatusChange)
    }
    
    func testDebugReport() async throws {
        installStubHandlers()
        _ = try await store.activate("LICENSE-DEBUG-TEST")
        
        let report = store.debugReport()
        
        XCTAssertEqual(report["sdk_version"] as? String, LicenseSeatConfig.sdkVersion)
        XCTAssertNotNil(report["status"] as? String)
        XCTAssertEqual(report["has_seat"] as? Bool, true)
        
        // Check redacted license info
        XCTAssertNotNil(report["license_key_prefix"] as? String)
        XCTAssertTrue((report["license_key_prefix"] as? String)?.hasSuffix("...") == true)
        XCTAssertNotNil(report["device_id_hash"])
        XCTAssertNotNil(report["activated_at"])
        XCTAssertNotNil(report["last_validated"])
    }
    
    #if canImport(Combine)
    func testStatusPublisherUpdates() async throws {
        installStubHandlers()

        if case .inactive = store.status {
            // Expected initial state.
        } else {
            XCTFail("Store should begin inactive")
        }

        let exp = expectation(description: "licensed status published")

        store.$status
            .dropFirst()
            .first { status in
                switch status {
                case .active, .offlineValid:
                    return true
                default:
                    return false
                }
            }
            .sink { _ in
                exp.fulfill()
            }
            .store(in: &cancellables)

        _ = try await store.activate("LICENSE-STATUS-TEST")

        await assertFulfillment(of: [exp], timeout: 2.0)

        switch store.status {
        case .active, .offlineValid:
            // Expected licensed state.
            break
        default:
            XCTFail("Store should publish a licensed status after activation")
        }
    }
    #endif

    func testValidationPassThroughRefreshesStatus() async throws {
        installStubHandlers()
        let license = try await store.activate("LICENSE-STORE-VALIDATE")

        let validation = try await store.validate(licenseKey: license.licenseKey)

        XCTAssertTrue(validation.valid)
        if case .active = store.status {
            // Expected.
        } else {
            XCTFail("Store should expose the validated status before returning")
        }
    }

    func testHeartbeatFailureRefreshesObservableRevocationBeforeThrowing() async throws {
        installStubHandlers()
        _ = try await store.activate("LICENSE-STORE-HEARTBEAT")
        await store.seat?.offlineSyncTask?.value

        MockURLProtocol.requestHandler = { request in
            let payload = [
                "error": ["code": "license_revoked", "message": "License revoked"]
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

        do {
            try await store.heartbeat()
            XCTFail("Expected revoked heartbeat error")
        } catch let error as APIError {
            XCTAssertEqual(error.code, "license_revoked")
        }

        XCTAssertNil(store.seat?.currentLicense())
        if case .inactive = store.status {
            // State is synchronized by the pass-through's defer, not a later publisher turn.
        } else {
            XCTFail("Store must expose terminal heartbeat invalidation before throwing")
        }
    }

    func testResetPassThroughClearsLicenseAndObservableState() async throws {
        installStubHandlers()
        _ = try await store.activate("LICENSE-STORE-RESET")

        store.reset()

        XCTAssertNil(store.seat?.currentLicense())
        XCTAssertNil(store.nextAutoValidationAt)
        if case .inactive = store.status {
            // Expected.
        } else {
            XCTFail("Store should be inactive immediately after reset")
        }
    }
    
    func testActivationError() async {
        // Configure handlers to return v1 error format
        MockURLProtocol.requestHandler = { request in
            if request.url!.path.contains("/activate") {
                let error: [String: Any] = [
                    "error": [
                        "code": "seat_limit_exceeded",
                        "message": "License already activated on another device"
                    ]
                ]
                let data = try JSONSerialization.data(withJSONObject: error)
                let resp = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 409,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!
                return (resp, data)
            }
            return (HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!, Data())
        }

        do {
            _ = try await store.activate("ALREADY-USED-KEY")
            XCTFail("Should have thrown activation error")
        } catch {
            // Expected - verify it's an API error
            XCTAssertNotNil(error as? APIError)
        }
    }
    
    #if canImport(Combine)
    func testEntitlementPublisher() async throws {
        installStubHandlers()
        
        // First activate a license
        _ = try await store.activate("LICENSE-ENT-TEST")
        
        // Now subscribe to entitlement changes
        let exp = expectation(description: "entitlement status received")
        var receivedStatus: EntitlementStatus?
        
        store.entitlementPublisher(for: "test-feature")
            .first()
            .sink { status in
                receivedStatus = status
                exp.fulfill()
            }
            .store(in: &cancellables)
        
        await assertFulfillment(of: [exp], timeout: 2.0)
        
        // After activation, a non-existent entitlement should be .notFound
        XCTAssertNotNil(receivedStatus)
        XCTAssertFalse(receivedStatus!.active)
        XCTAssertNotNil(receivedStatus!.reason)
    }
    
    func testEntitlementPublisherWithoutSeat() async {
        let unconfiguredStore = LicenseSeatStore()

        let exp = expectation(description: "entitlement publisher delivers value")
        var received: EntitlementStatus?

        let cancellable = unconfiguredStore.entitlementPublisher(for: "test")
            .sink { status in
                received = status
                exp.fulfill()
            }

        await assertFulfillment(of: [exp], timeout: 1.0)
        XCTAssertNotNil(received)
        XCTAssertFalse(received!.active)
        XCTAssertNotNil(received!.reason)
        withExtendedLifetime(cancellable) {}
    }
    #endif
    
    func testDeactivation() async throws {
        installStubHandlers()

        // Add deactivation handler (v1 path)
        let originalHandler = MockURLProtocol.requestHandler
        MockURLProtocol.requestHandler = { request in
            if request.url!.path.contains("/deactivate") {
                let result: [String: Any] = [
                    "object": "deactivation",
                    "activation_id": "act-12345-uuid",
                    "deactivated_at": ISO8601DateFormatter().string(from: Date())
                ]
                let data = try JSONSerialization.data(withJSONObject: result)
                let resp = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!
                return (resp, data)
            }
            return try originalHandler!(request)
        }
        
        // Activate first
        _ = try await store.activate("LICENSE-DEACTIVATE-TEST")

        // Verify we have a license (status could be .active or .pending depending on validation)
        switch store.status {
        case .active, .pending, .offlineValid:
            // Good - we have an activated license
            break
        case .inactive, .invalid, .offlineInvalid:
            XCTFail("Should have a license before deactivation, got: \(store.status)")
        }
        
        // Deactivate
        try await store.deactivate()
        
        // Status should update
        _ = try? await Task.sleep(nanoseconds: 100_000_000) // 0.1s for propagation
        
        if case .inactive = store.status {
            // Expected
        } else {
            XCTFail("Should be inactive after deactivation")
        }
    }
    
    #if canImport(SwiftUI)
    func testEntitlementStatePropertyWrapper() async throws {
        installStubHandlers()

        // Configure shared store
        let conf = URLSessionConfiguration.ephemeral
        conf.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: conf)
        LicenseSeatStore.shared.configure(
            apiKey: "test_key",
            apiBaseURL: URL(string: "https://api.test.com")!,
            force: true,
            urlSession: session
        ) { cfg in
            cfg.productSlug = Self.testProductSlug
            cfg.deviceIdentifier = "test-device"
        }
        
        _ = try await LicenseSeatStore.shared.activate("LICENSE-ENT-TEST")
        _ = try? await Task.sleep(nanoseconds: 100_000_000)
        
        struct EntitlementView: View {
            @EntitlementState("premium") var hasPremium
            var body: some View { EmptyView() }
        }
        
        let view = EntitlementView()
        // Should be false since we don't return entitlements in mock
        XCTAssertFalse(view.hasPremium)
        
        // Test projected value
        let fullStatus = view.$hasPremium
        XCTAssertFalse(fullStatus.active)
        XCTAssertNotNil(fullStatus.reason)
    }
    #endif
}
