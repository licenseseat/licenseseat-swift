import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(Combine)
import Combine
#endif
@testable import LicenseSeat

/// Records URLProtocol callbacks without relying on XCTest's inverted async
/// expectation handling, which differs between Swift 5.10 and newer XCTest.
private final class LockedRequestCount: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0

    func increment() {
        lock.lock()
        storage += 1
        lock.unlock()
    }

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

// swiftlint:disable implicitly_unwrapped_optional
@MainActor
final class AutoValidationTests: LicenseSeatTestCase {
    private var sdk: LicenseSeat!
    private var cancellables: Set<AnyCancellable> = []
    
    override func tearDown() {
        MainActor.assumeIsolated {
            sdk?.reset()
            sdk = nil
            MockURLProtocol.reset()
            cancellables.removeAll()
        }
        super.tearDown()
    }
    
    private static let testProductSlug = "test-app"

    @MainActor
    func testAutoValidationCycleFires() async throws {
        let licenseKey = "LIC-TEST"

        // Stub network responses with v1 API paths
        MockURLProtocol.requestHandler = { request in
            guard let url = request.url else {
                throw URLError(.badURL)
            }
            let path = url.path
            var json: [String: Any] = [:]
            var statusCode = 200

            if path.contains("/activate") {
                statusCode = 201
                json = [
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
            } else if path.contains("/validate") {
                json = [
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
            } else {
                // Return an empty JSON object for any other endpoint
                json = [:]
            }
            let data = try JSONSerialization.data(withJSONObject: json)
            let response = HTTPURLResponse(
                url: url,
                statusCode: statusCode,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, data)
        }

        // URLSession configured with MockURLProtocol
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)

        // Configure SDK with very short auto-validation interval and productSlug
        let config = LicenseSeatConfig(
            apiBaseUrl: "https://example.com",
            apiKey: "test-api-key",
            productSlug: Self.testProductSlug,
            storagePrefix: "auto_validation_test_\(UUID().uuidString)_",
            deviceIdentifier: "test-device",
            autoValidateInterval: 0.2,
            debug: false
        )
        sdk = LicenseSeat(config: config, urlSession: session)

        // Expect at least one autovalidation:cycle event within 1 second
        let fired = expectation(description: "Auto-validation cycle fired")
        var didFulfill = false
        let cancellable = sdk.on("autovalidation:cycle") { _ in
            if !didFulfill {
                didFulfill = true
                fired.fulfill()
            }
        }
        cancellables.insert(cancellable)

        // Activate license (starts auto-validation)
        _ = try await sdk.activate(licenseKey: licenseKey)

        await assertFulfillment(of: [fired], timeout: 1.0)
    }

    @MainActor
    func testDisabledAutoValidationDoesNotSendLaunchRequestForCachedLicense() async {
        let requestCount = LockedRequestCount()

        MockURLProtocol.requestHandler = { request in
            requestCount.increment()
            let url = try XCTUnwrap(request.url)
            let response = try XCTUnwrap(HTTPURLResponse(
                url: url,
                statusCode: 500,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            ))
            return (response, Data("{}".utf8))
        }

        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: sessionConfiguration)
        let config = LicenseSeatConfig(
            apiBaseUrl: "https://example.com",
            apiKey: "test-api-key",
            productSlug: Self.testProductSlug,
            storagePrefix: "disabled_auto_validation_test_\(UUID().uuidString)_",
            deviceIdentifier: "test-device",
            autoValidateInterval: 0,
            heartbeatInterval: 0,
            offlineTokenRefreshInterval: 0
        )

        // The initialization task is main-actor isolated, so this synchronous
        // seed deterministically precedes its first read of protected storage.
        sdk = LicenseSeat(config: config, urlSession: session)
        XCTAssertTrue(sdk.cache.setLicense(License(
            licenseKey: "CACHED-LICENSE",
            deviceId: "test-device",
            activationId: "cached-activation",
            activatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            lastValidated: Date(timeIntervalSince1970: 1_700_000_100)
        )))

        await sdk.waitForInitialization()

        XCTAssertNil(sdk.validationTask)
        XCTAssertNil(sdk.backgroundValidationTask)
        // Yield the main actor long enough for any incorrectly scheduled launch
        // work to reach URLSession, then inspect a lock-protected counter. The
        // async XCTWaiter API returned `.timedOut` for an unfulfilled inverted
        // expectation on Xcode 15.4 even though that is this test's success case.
        _ = try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(requestCount.value, 0)
    }

    @MainActor
    func testPublicBackgroundTaskControlStartsAndStopsSDKWork() async throws {
        let config = LicenseSeatConfig(
            apiBaseUrl: "https://example.com",
            apiKey: "test-api-key",
            productSlug: Self.testProductSlug,
            storagePrefix: "public_control_test_\(UUID().uuidString)_",
            deviceIdentifier: "test-device",
            autoValidateInterval: 600,
            heartbeatInterval: 600
        )
        sdk = LicenseSeat(config: config, urlSession: URLSession(configuration: .ephemeral))
        await sdk.waitForInitialization()

        XCTAssertFalse(sdk.isAutoValidating)
        XCTAssertNil(sdk.nextAutoValidationAt)

        let startedAt = Date()
        sdk.startAutoValidation(licenseKey: "PUBLIC-CONTROL-LICENSE")
        sdk.startHeartbeat()

        XCTAssertTrue(sdk.isAutoValidating)
        XCTAssertNotNil(sdk.heartbeatTask)
        let nextRun = try XCTUnwrap(sdk.nextAutoValidationAt)
        XCTAssertGreaterThanOrEqual(nextRun, startedAt.addingTimeInterval(600))
        XCTAssertLessThanOrEqual(nextRun, Date().addingTimeInterval(600))

        sdk.stopAutoValidation()
        sdk.stopHeartbeat()

        XCTAssertFalse(sdk.isAutoValidating)
        XCTAssertNil(sdk.nextAutoValidationAt)
        XCTAssertNil(sdk.heartbeatTask)
    }

    @MainActor
    func testDisabledIntervalLeavesNextAutoValidationUnset() async throws {
        let config = LicenseSeatConfig(
            apiBaseUrl: "https://example.com",
            apiKey: "test-api-key",
            productSlug: Self.testProductSlug,
            storagePrefix: "public_control_disabled_\(UUID().uuidString)_",
            deviceIdentifier: "test-device",
            autoValidateInterval: 0,
            heartbeatInterval: 0
        )
        sdk = LicenseSeat(config: config, urlSession: URLSession(configuration: .ephemeral))
        await sdk.waitForInitialization()

        sdk.startAutoValidation(licenseKey: "PUBLIC-CONTROL-LICENSE")
        sdk.startHeartbeat()

        XCTAssertFalse(sdk.isAutoValidating)
        XCTAssertNil(sdk.nextAutoValidationAt)
        XCTAssertNil(sdk.heartbeatTask)
    }
}
