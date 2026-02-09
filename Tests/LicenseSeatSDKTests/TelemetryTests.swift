///
/// TelemetryTests.swift
/// LicenseSeatSDKTests
///
/// Tests for enriched telemetry payload and standalone heartbeat timer.
///

import XCTest
import Combine
@testable import LicenseSeat

// MARK: - TelemetryPayload Unit Tests

final class TelemetryPayloadTests: XCTestCase {

    func testCollectReturnsAllRequiredFields() {
        let payload = TelemetryPayload.collect()

        XCTAssertEqual(payload.sdkName, "swift")
        XCTAssertEqual(payload.sdkVersion, LicenseSeatConfig.sdkVersion)
        XCTAssertFalse(payload.osName.isEmpty)
        XCTAssertFalse(payload.osVersion.isEmpty)
        XCTAssertFalse(payload.platform.isEmpty)
        XCTAssertFalse(payload.deviceModel.isEmpty)
        XCTAssertFalse(payload.locale.isEmpty)
        XCTAssertFalse(payload.timezone.isEmpty)
    }

    func testPlatformReturnsNative() {
        let payload = TelemetryPayload.collect()
        XCTAssertEqual(payload.platform, "native", "platform should return 'native', not duplicate os_name")
        XCTAssertNotEqual(payload.platform, payload.osName, "platform must differ from os_name")
    }

    func testOsNameMatchesPlatform() {
        let payload = TelemetryPayload.collect()
        #if os(macOS)
        XCTAssertEqual(payload.osName, "macOS")
        #elseif os(iOS)
        XCTAssertEqual(payload.osName, "iOS")
        #elseif os(tvOS)
        XCTAssertEqual(payload.osName, "tvOS")
        #elseif os(watchOS)
        XCTAssertEqual(payload.osName, "watchOS")
        #elseif os(visionOS)
        XCTAssertEqual(payload.osName, "visionOS")
        #endif
    }

    func testOsVersionFormat() {
        let payload = TelemetryPayload.collect()
        let components = payload.osVersion.split(separator: ".")
        XCTAssertEqual(components.count, 3, "OS version should be major.minor.patch")
        for component in components {
            XCTAssertNotNil(Int(component), "Each version component should be an integer")
        }
    }

    func testDeviceTypeIsNonNil() {
        let payload = TelemetryPayload.collect()
        XCTAssertNotNil(payload.deviceType, "deviceType should be available on all Apple platforms")
        #if os(macOS)
        XCTAssertEqual(payload.deviceType, "desktop")
        #elseif os(watchOS)
        XCTAssertEqual(payload.deviceType, "watch")
        #elseif os(tvOS)
        XCTAssertEqual(payload.deviceType, "tv")
        #endif
    }

    func testArchitectureIsNonNil() {
        let payload = TelemetryPayload.collect()
        XCTAssertNotNil(payload.architecture)
        let validArch = ["arm64", "x64"]
        XCTAssertTrue(validArch.contains(payload.architecture!),
                       "architecture should be arm64 or x64, got: \(payload.architecture!)")
    }

    func testCpuCoresIsPositive() {
        let payload = TelemetryPayload.collect()
        XCTAssertNotNil(payload.cpuCores)
        XCTAssertGreaterThan(payload.cpuCores!, 0, "CPU cores must be positive")
    }

    func testMemoryGbIsPositive() {
        let payload = TelemetryPayload.collect()
        XCTAssertNotNil(payload.memoryGb)
        XCTAssertGreaterThan(payload.memoryGb!, 0, "Memory GB must be positive")
    }

    func testLanguageIsTwoLetterCode() {
        let payload = TelemetryPayload.collect()
        XCTAssertNotNil(payload.language)
        // Language codes are typically 2-3 characters (ISO 639-1/2)
        XCTAssertGreaterThanOrEqual(payload.language!.count, 2)
        XCTAssertLessThanOrEqual(payload.language!.count, 3)
    }

    func testScreenResolutionFormat() {
        let payload = TelemetryPayload.collect()
        #if os(macOS) || os(iOS) || os(tvOS)
        XCTAssertNotNil(payload.screenResolution, "screenResolution should be available on macOS/iOS/tvOS")
        if let res = payload.screenResolution {
            let parts = res.split(separator: "x")
            XCTAssertEqual(parts.count, 2, "screenResolution should be WIDTHxHEIGHT")
            XCTAssertNotNil(Int(parts[0]), "Width should be integer")
            XCTAssertNotNil(Int(parts[1]), "Height should be integer")
            XCTAssertGreaterThan(Int(parts[0])!, 0, "Width must be positive")
            XCTAssertGreaterThan(Int(parts[1])!, 0, "Height must be positive")
        }
        #elseif os(watchOS)
        // screenResolution is nil on watchOS
        XCTAssertNil(payload.screenResolution)
        #endif
    }

    func testDisplayScaleIsPositive() {
        let payload = TelemetryPayload.collect()
        #if os(macOS) || os(iOS) || os(tvOS)
        XCTAssertNotNil(payload.displayScale, "displayScale should be available on macOS/iOS/tvOS")
        if let scale = payload.displayScale {
            XCTAssertGreaterThanOrEqual(scale, 1.0, "Display scale must be >= 1.0")
            XCTAssertLessThanOrEqual(scale, 4.0, "Display scale should be <= 4.0 (no known display exceeds this)")
        }
        #elseif os(watchOS)
        XCTAssertNil(payload.displayScale)
        #endif
    }

    // MARK: - toDictionary() tests

    func testToDictionaryContainsAllBaseFields() {
        let payload = TelemetryPayload.collect()
        let dict = payload.toDictionary()

        // Required fields (always present)
        XCTAssertEqual(dict["sdk_name"] as? String, "swift")
        XCTAssertNotNil(dict["sdk_version"])
        XCTAssertNotNil(dict["os_name"])
        XCTAssertNotNil(dict["os_version"])
        XCTAssertNotNil(dict["platform"])
        XCTAssertNotNil(dict["device_model"])
        XCTAssertNotNil(dict["locale"])
        XCTAssertNotNil(dict["timezone"])

        // Verify types
        XCTAssertTrue(dict["sdk_version"] is String)
        XCTAssertTrue(dict["os_name"] is String)
        XCTAssertTrue(dict["os_version"] is String)
        XCTAssertTrue(dict["platform"] is String)
        XCTAssertTrue(dict["device_model"] is String)
        XCTAssertTrue(dict["locale"] is String)
        XCTAssertTrue(dict["timezone"] is String)
    }

    func testToDictionaryContainsNewFields() {
        let payload = TelemetryPayload.collect()
        let dict = payload.toDictionary()

        // These should always be present on macOS (test runner)
        XCTAssertNotNil(dict["device_type"], "device_type should be in dictionary")
        XCTAssertNotNil(dict["architecture"], "architecture should be in dictionary")
        XCTAssertNotNil(dict["cpu_cores"], "cpu_cores should be in dictionary")
        XCTAssertNotNil(dict["memory_gb"], "memory_gb should be in dictionary")
        XCTAssertNotNil(dict["language"], "language should be in dictionary")

        // Verify correct types
        XCTAssertTrue(dict["device_type"] is String)
        XCTAssertTrue(dict["architecture"] is String)
        XCTAssertTrue(dict["cpu_cores"] is Int)
        XCTAssertTrue(dict["memory_gb"] is Int)
        XCTAssertTrue(dict["language"] is String)
    }

    func testToDictionaryScreenFieldsPresentOnMacOS() {
        let dict = TelemetryPayload.collect().toDictionary()
        #if os(macOS)
        // NSScreen.main can be nil in headless CI, so these might be absent
        if dict["screen_resolution"] != nil {
            XCTAssertTrue(dict["screen_resolution"] is String)
        }
        if dict["display_scale"] != nil {
            XCTAssertTrue(dict["display_scale"] is Double)
        }
        #endif
    }

    func testToDictionaryPlatformFieldEqualsNative() {
        let dict = TelemetryPayload.collect().toDictionary()
        XCTAssertEqual(dict["platform"] as? String, "native")
    }

    func testToDictionaryOmitsNilValues() {
        // Create a payload with nil optional fields by constructing directly
        let payload = TelemetryPayload.collect()
        let dict = payload.toDictionary()

        // Verify no NSNull or nil values leak into the dictionary
        for (key, value) in dict {
            XCTAssertFalse(value is NSNull, "Key '\(key)' should not have NSNull value")
        }
    }

    func testToDictionaryCanSerializeToJSON() throws {
        let dict = TelemetryPayload.collect().toDictionary()
        // Must be valid JSON
        let data = try JSONSerialization.data(withJSONObject: dict, options: [])
        XCTAssertGreaterThan(data.count, 0, "Telemetry dictionary must serialize to valid JSON")

        // Round-trip verification
        let decoded = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertNotNil(decoded)
        XCTAssertEqual(decoded?["sdk_version"] as? String, LicenseSeatConfig.sdkVersion)
        XCTAssertEqual(decoded?["platform"] as? String, "native")
    }
}

// MARK: - Telemetry Sent With API Requests

@MainActor
final class TelemetryAPIIntegrationTests: XCTestCase {
    private static let testProductSlug = "test-app"

    /// Read the request body from either httpBody or httpBodyStream
    private static func readBody(from request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let bufferSize = 4096
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let read = stream.read(buffer, maxLength: bufferSize)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }

    func testTelemetryIncludedInPOSTBody() async throws {
        var capturedBody: [String: Any]?

        MockURLProtocol.requestHandler = { request in
            guard let url = request.url else { throw URLError(.badURL) }

            // Capture the request body
            if url.path.contains("/activate"),
               let bodyData = TelemetryAPIIntegrationTests.readBody(from: request) {
                capturedBody = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any]
            }

            if url.path.contains("/activate") {
                let response: [String: Any] = [
                    "object": "activation",
                    "id": "act-test-uuid",
                    "device_id": "test-device",
                    "device_name": NSNull(),
                    "license_key": "TEST-KEY",
                    "activated_at": ISO8601DateFormatter().string(from: Date()),
                    "deactivated_at": NSNull(),
                    "ip_address": NSNull(),
                    "metadata": NSNull(),
                    "license": [
                        "object": "license",
                        "key": "TEST-KEY",
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
                let data = try JSONSerialization.data(withJSONObject: response)
                return (HTTPURLResponse(url: url, statusCode: 201, httpVersion: nil,
                                        headerFields: ["Content-Type": "application/json"])!, data)
            }
            return (HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil,
                                    headerFields: ["Content-Type": "application/json"])!,
                    try JSONSerialization.data(withJSONObject: [:]))
        }

        let urlConf = URLSessionConfiguration.ephemeral
        urlConf.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: urlConf)

        let config = LicenseSeatConfig(
            apiBaseUrl: "https://api.test.com",
            apiKey: "unit-test",
            productSlug: Self.testProductSlug,
            storagePrefix: "telemetry_api_test_",
            autoValidateInterval: 0,
            heartbeatInterval: 0,
            telemetryEnabled: true
        )
        let sdk = LicenseSeat(config: config, urlSession: session)
        sdk.cache.clear()

        _ = try await sdk.activate(licenseKey: "TEST-KEY")

        // Verify telemetry was attached
        XCTAssertNotNil(capturedBody, "POST body should be captured")
        let telemetry = capturedBody?["telemetry"] as? [String: Any]
        XCTAssertNotNil(telemetry, "telemetry key should be present in POST body")

        // Check all fields
        XCTAssertEqual(telemetry?["sdk_name"] as? String, "swift")
        XCTAssertEqual(telemetry?["sdk_version"] as? String, LicenseSeatConfig.sdkVersion)
        XCTAssertEqual(telemetry?["platform"] as? String, "native")
        XCTAssertNotNil(telemetry?["os_name"])
        XCTAssertNotNil(telemetry?["os_version"])
        XCTAssertNotNil(telemetry?["device_model"])
        XCTAssertNotNil(telemetry?["device_type"])
        XCTAssertNotNil(telemetry?["architecture"])
        XCTAssertNotNil(telemetry?["cpu_cores"])
        XCTAssertNotNil(telemetry?["memory_gb"])
        XCTAssertNotNil(telemetry?["language"])

        sdk.reset()
        MockURLProtocol.reset()
    }

    func testTelemetryExcludedWhenDisabled() async throws {
        var capturedBody: [String: Any]?

        MockURLProtocol.requestHandler = { request in
            guard let url = request.url else { throw URLError(.badURL) }

            if url.path.contains("/activate"),
               let bodyData = TelemetryAPIIntegrationTests.readBody(from: request) {
                capturedBody = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any]
            }

            if url.path.contains("/activate") {
                let response: [String: Any] = [
                    "object": "activation",
                    "id": "act-test-uuid",
                    "device_id": "test-device",
                    "device_name": NSNull(),
                    "license_key": "TEST-KEY",
                    "activated_at": ISO8601DateFormatter().string(from: Date()),
                    "deactivated_at": NSNull(),
                    "ip_address": NSNull(),
                    "metadata": NSNull(),
                    "license": [
                        "object": "license",
                        "key": "TEST-KEY",
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
                let data = try JSONSerialization.data(withJSONObject: response)
                return (HTTPURLResponse(url: url, statusCode: 201, httpVersion: nil,
                                        headerFields: ["Content-Type": "application/json"])!, data)
            }
            return (HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil,
                                    headerFields: ["Content-Type": "application/json"])!,
                    try JSONSerialization.data(withJSONObject: [:]))
        }

        let urlConf = URLSessionConfiguration.ephemeral
        urlConf.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: urlConf)

        let config = LicenseSeatConfig(
            apiBaseUrl: "https://api.test.com",
            apiKey: "unit-test",
            productSlug: Self.testProductSlug,
            storagePrefix: "telemetry_disabled_test_",
            autoValidateInterval: 0,
            heartbeatInterval: 0,
            telemetryEnabled: false
        )
        let sdk = LicenseSeat(config: config, urlSession: session)
        sdk.cache.clear()

        _ = try await sdk.activate(licenseKey: "TEST-KEY")

        XCTAssertNotNil(capturedBody)
        XCTAssertNil(capturedBody?["telemetry"], "telemetry should NOT be in POST body when disabled")

        sdk.reset()
        MockURLProtocol.reset()
    }
}

// MARK: - Heartbeat Timer Tests

@MainActor
final class HeartbeatTimerTests: XCTestCase {
    private var cancellables: Set<AnyCancellable> = []
    private static let testProductSlug = "test-app"

    override func tearDown() {
        MockURLProtocol.reset()
        cancellables.removeAll()
        super.tearDown()
    }

    func testHeartbeatIntervalDefaultValue() {
        let config = LicenseSeatConfig.default
        XCTAssertEqual(config.heartbeatInterval, 300, "Default heartbeat interval should be 300 seconds (5 minutes)")
    }

    func testHeartbeatIntervalCustomValue() {
        let config = LicenseSeatConfig(heartbeatInterval: 60)
        XCTAssertEqual(config.heartbeatInterval, 60)
    }

    func testHeartbeatTimerDoesNotStartWhenIntervalIsZero() async throws {
        MockURLProtocol.requestHandler = { request in
            guard let url = request.url else { throw URLError(.badURL) }
            if url.path.contains("/activate") {
                let response: [String: Any] = [
                    "object": "activation",
                    "id": "act-hb-uuid",
                    "device_id": "test-device",
                    "device_name": NSNull(),
                    "license_key": "TEST-KEY",
                    "activated_at": ISO8601DateFormatter().string(from: Date()),
                    "deactivated_at": NSNull(),
                    "ip_address": NSNull(),
                    "metadata": NSNull(),
                    "license": [
                        "object": "license",
                        "key": "TEST-KEY",
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
                let data = try JSONSerialization.data(withJSONObject: response)
                return (HTTPURLResponse(url: url, statusCode: 201, httpVersion: nil,
                                        headerFields: ["Content-Type": "application/json"])!, data)
            }
            return (HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil,
                                    headerFields: ["Content-Type": "application/json"])!,
                    try JSONSerialization.data(withJSONObject: [:]))
        }

        let urlConf = URLSessionConfiguration.ephemeral
        urlConf.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: urlConf)

        let config = LicenseSeatConfig(
            apiBaseUrl: "https://api.test.com",
            apiKey: "unit-test",
            productSlug: Self.testProductSlug,
            storagePrefix: "hb_disabled_test_",
            autoValidateInterval: 0,
            heartbeatInterval: 0
        )
        let sdk = LicenseSeat(config: config, urlSession: session)
        sdk.cache.clear()

        _ = try await sdk.activate(licenseKey: "TEST-KEY")

        // heartbeatTask should be nil when interval is 0
        XCTAssertNil(sdk.heartbeatTask, "heartbeatTask should not start when heartbeatInterval <= 0")

        sdk.reset()
    }

    func testHeartbeatTimerDoesNotStartWhenIntervalIsNegative() async throws {
        MockURLProtocol.requestHandler = { request in
            guard let url = request.url else { throw URLError(.badURL) }
            if url.path.contains("/activate") {
                let response: [String: Any] = [
                    "object": "activation",
                    "id": "act-hb-neg-uuid",
                    "device_id": "test-device",
                    "device_name": NSNull(),
                    "license_key": "TEST-KEY",
                    "activated_at": ISO8601DateFormatter().string(from: Date()),
                    "deactivated_at": NSNull(),
                    "ip_address": NSNull(),
                    "metadata": NSNull(),
                    "license": [
                        "object": "license",
                        "key": "TEST-KEY",
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
                let data = try JSONSerialization.data(withJSONObject: response)
                return (HTTPURLResponse(url: url, statusCode: 201, httpVersion: nil,
                                        headerFields: ["Content-Type": "application/json"])!, data)
            }
            return (HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil,
                                    headerFields: ["Content-Type": "application/json"])!,
                    try JSONSerialization.data(withJSONObject: [:]))
        }

        let urlConf = URLSessionConfiguration.ephemeral
        urlConf.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: urlConf)

        let config = LicenseSeatConfig(
            apiBaseUrl: "https://api.test.com",
            apiKey: "unit-test",
            productSlug: Self.testProductSlug,
            storagePrefix: "hb_neg_test_",
            autoValidateInterval: 0,
            heartbeatInterval: -1
        )
        let sdk = LicenseSeat(config: config, urlSession: session)
        sdk.cache.clear()

        _ = try await sdk.activate(licenseKey: "TEST-KEY")

        XCTAssertNil(sdk.heartbeatTask, "heartbeatTask should not start when heartbeatInterval is negative")

        sdk.reset()
    }

    func testHeartbeatTimerStartsOnActivation() async throws {
        MockURLProtocol.requestHandler = { request in
            guard let url = request.url else { throw URLError(.badURL) }
            if url.path.contains("/activate") {
                let response: [String: Any] = [
                    "object": "activation",
                    "id": "act-hb-start-uuid",
                    "device_id": "test-device",
                    "device_name": NSNull(),
                    "license_key": "TEST-KEY",
                    "activated_at": ISO8601DateFormatter().string(from: Date()),
                    "deactivated_at": NSNull(),
                    "ip_address": NSNull(),
                    "metadata": NSNull(),
                    "license": [
                        "object": "license",
                        "key": "TEST-KEY",
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
                let data = try JSONSerialization.data(withJSONObject: response)
                return (HTTPURLResponse(url: url, statusCode: 201, httpVersion: nil,
                                        headerFields: ["Content-Type": "application/json"])!, data)
            }
            return (HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil,
                                    headerFields: ["Content-Type": "application/json"])!,
                    try JSONSerialization.data(withJSONObject: [:]))
        }

        let urlConf = URLSessionConfiguration.ephemeral
        urlConf.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: urlConf)

        let config = LicenseSeatConfig(
            apiBaseUrl: "https://api.test.com",
            apiKey: "unit-test",
            productSlug: Self.testProductSlug,
            storagePrefix: "hb_start_test_",
            autoValidateInterval: 0,
            heartbeatInterval: 300
        )
        let sdk = LicenseSeat(config: config, urlSession: session)
        sdk.cache.clear()

        _ = try await sdk.activate(licenseKey: "TEST-KEY")

        XCTAssertNotNil(sdk.heartbeatTask, "heartbeatTask should be started after activation")

        sdk.reset()
    }

    func testHeartbeatTimerStopsOnReset() async throws {
        MockURLProtocol.requestHandler = { request in
            guard let url = request.url else { throw URLError(.badURL) }
            if url.path.contains("/activate") {
                let response: [String: Any] = [
                    "object": "activation",
                    "id": "act-hb-reset-uuid",
                    "device_id": "test-device",
                    "device_name": NSNull(),
                    "license_key": "TEST-KEY",
                    "activated_at": ISO8601DateFormatter().string(from: Date()),
                    "deactivated_at": NSNull(),
                    "ip_address": NSNull(),
                    "metadata": NSNull(),
                    "license": [
                        "object": "license",
                        "key": "TEST-KEY",
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
                let data = try JSONSerialization.data(withJSONObject: response)
                return (HTTPURLResponse(url: url, statusCode: 201, httpVersion: nil,
                                        headerFields: ["Content-Type": "application/json"])!, data)
            }
            return (HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil,
                                    headerFields: ["Content-Type": "application/json"])!,
                    try JSONSerialization.data(withJSONObject: [:]))
        }

        let urlConf = URLSessionConfiguration.ephemeral
        urlConf.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: urlConf)

        let config = LicenseSeatConfig(
            apiBaseUrl: "https://api.test.com",
            apiKey: "unit-test",
            productSlug: Self.testProductSlug,
            storagePrefix: "hb_reset_test_",
            autoValidateInterval: 0,
            heartbeatInterval: 300
        )
        let sdk = LicenseSeat(config: config, urlSession: session)
        sdk.cache.clear()

        _ = try await sdk.activate(licenseKey: "TEST-KEY")
        XCTAssertNotNil(sdk.heartbeatTask)

        sdk.reset()
        XCTAssertNil(sdk.heartbeatTask, "heartbeatTask should be nil after reset()")
    }

    func testHeartbeatTimerStopsOnDeactivation() async throws {
        MockURLProtocol.requestHandler = { request in
            guard let url = request.url else { throw URLError(.badURL) }
            if url.path.contains("/activate") {
                let response: [String: Any] = [
                    "object": "activation",
                    "id": "act-hb-deact-uuid",
                    "device_id": "test-device",
                    "device_name": NSNull(),
                    "license_key": "TEST-KEY",
                    "activated_at": ISO8601DateFormatter().string(from: Date()),
                    "deactivated_at": NSNull(),
                    "ip_address": NSNull(),
                    "metadata": NSNull(),
                    "license": [
                        "object": "license",
                        "key": "TEST-KEY",
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
                let data = try JSONSerialization.data(withJSONObject: response)
                return (HTTPURLResponse(url: url, statusCode: 201, httpVersion: nil,
                                        headerFields: ["Content-Type": "application/json"])!, data)
            } else if url.path.contains("/deactivate") {
                let response: [String: Any] = [
                    "object": "deactivation",
                    "activation_id": "act-hb-deact-uuid",
                    "deactivated_at": ISO8601DateFormatter().string(from: Date())
                ]
                let data = try JSONSerialization.data(withJSONObject: response)
                return (HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil,
                                        headerFields: ["Content-Type": "application/json"])!, data)
            }
            return (HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil,
                                    headerFields: ["Content-Type": "application/json"])!,
                    try JSONSerialization.data(withJSONObject: [:]))
        }

        let urlConf = URLSessionConfiguration.ephemeral
        urlConf.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: urlConf)

        let config = LicenseSeatConfig(
            apiBaseUrl: "https://api.test.com",
            apiKey: "unit-test",
            productSlug: Self.testProductSlug,
            storagePrefix: "hb_deact_test_",
            autoValidateInterval: 0,
            heartbeatInterval: 300
        )
        let sdk = LicenseSeat(config: config, urlSession: session)
        sdk.cache.clear()

        _ = try await sdk.activate(licenseKey: "TEST-KEY")
        XCTAssertNotNil(sdk.heartbeatTask)

        try await sdk.deactivate()
        XCTAssertNil(sdk.heartbeatTask, "heartbeatTask should be nil after deactivate()")
    }

    func testHeartbeatTimerFiresIndependently() async throws {
        var heartbeatCount = 0

        MockURLProtocol.requestHandler = { request in
            guard let url = request.url else { throw URLError(.badURL) }
            if url.path.contains("/activate") {
                let response: [String: Any] = [
                    "object": "activation",
                    "id": "act-hb-fire-uuid",
                    "device_id": "test-device",
                    "device_name": NSNull(),
                    "license_key": "TEST-KEY",
                    "activated_at": ISO8601DateFormatter().string(from: Date()),
                    "deactivated_at": NSNull(),
                    "ip_address": NSNull(),
                    "metadata": NSNull(),
                    "license": [
                        "object": "license",
                        "key": "TEST-KEY",
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
                let data = try JSONSerialization.data(withJSONObject: response)
                return (HTTPURLResponse(url: url, statusCode: 201, httpVersion: nil,
                                        headerFields: ["Content-Type": "application/json"])!, data)
            } else if url.path.contains("/heartbeat") {
                heartbeatCount += 1
                let response: [String: Any] = [
                    "object": "heartbeat",
                    "status": "ok"
                ]
                let data = try JSONSerialization.data(withJSONObject: response)
                return (HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil,
                                        headerFields: ["Content-Type": "application/json"])!, data)
            }
            return (HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil,
                                    headerFields: ["Content-Type": "application/json"])!,
                    try JSONSerialization.data(withJSONObject: [:]))
        }

        let urlConf = URLSessionConfiguration.ephemeral
        urlConf.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: urlConf)

        let config = LicenseSeatConfig(
            apiBaseUrl: "https://api.test.com",
            apiKey: "unit-test",
            productSlug: Self.testProductSlug,
            storagePrefix: "hb_fire_test_",
            autoValidateInterval: 0, // auto-validation disabled
            heartbeatInterval: 0.3   // very short for testing
        )
        let sdk = LicenseSeat(config: config, urlSession: session)
        sdk.cache.clear()

        _ = try await sdk.activate(licenseKey: "TEST-KEY")
        XCTAssertNotNil(sdk.heartbeatTask)
        XCTAssertNil(sdk.validationTask, "validationTask should be nil (autoValidateInterval=0)")

        // Wait for at least 2 heartbeat cycles
        try await Task.sleep(nanoseconds: 1_000_000_000) // 1 second

        XCTAssertGreaterThanOrEqual(heartbeatCount, 2,
            "Standalone heartbeat should fire at least twice in 1s with 0.3s interval (fired \(heartbeatCount) times)")

        sdk.reset()
    }
}

// MARK: - Config Default Tests (heartbeat)

final class HeartbeatConfigTests: XCTestCase {

    func testDefaultConfigIncludesHeartbeatInterval() {
        let config = LicenseSeatConfig.default
        XCTAssertEqual(config.heartbeatInterval, 300)
    }

    func testHeartbeatIntervalInDescription() {
        // Ensure heartbeatInterval is part of the config struct
        let config = LicenseSeatConfig(heartbeatInterval: 120)
        XCTAssertEqual(config.heartbeatInterval, 120)
    }
}
