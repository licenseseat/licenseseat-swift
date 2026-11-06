//
//  StorageReadFailureTests.swift
//  LicenseSeatSDKTests
//
//  A failed protected read (locked Keychain: errSecInteractionNotAllowed,
//  errSecAuthFailed, …) is "unknown", never "not activated", and never purges.
//

import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import LicenseSeat

@MainActor
final class StorageReadFailureTests: LicenseSeatTestCase {
    private var sdk: LicenseSeat!
    private var storagePrefix = ""

    nonisolated private static func makeMockedSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private func makeSDK() -> LicenseSeat {
        LicenseSeat(
            config: LicenseSeatConfig(
                apiBaseUrl: "https://api.test.com",
                apiKey: "pk_test_storage",
                productSlug: "storage-app",
                storagePrefix: storagePrefix,
                deviceIdentifier: "storage-device-0001",
                autoValidateInterval: 0,
                heartbeatInterval: 0,
                maxRetries: 0
            ),
            urlSession: Self.makeMockedSession()
        )
    }

    override func setUp() async throws {
        _ = URLProtocol.registerClass(MockURLProtocol.self)
        MockURLProtocol.reset()
        MockURLProtocol.requestHandler = { _ in throw URLError(.notConnectedToInternet) }
        storagePrefix = "storage_read_failure_test_\(UUID().uuidString)_"
        sdk = makeSDK()
        await sdk.waitForInitialization()
        let validation = ValidationResponse(
            object: "validation_result", valid: true, code: nil, message: nil, warnings: nil,
            license: LicenseResponse(
                object: "license", key: "STORAGE-KEY-0001", status: "active", startsAt: nil,
                expiresAt: nil, mode: "hardware_locked", planKey: "pro", seatLimit: 1,
                activeSeats: 1, activeEntitlements: [], metadata: nil,
                product: Product(slug: "storage-app", name: "Storage App")
            ),
            activation: nil
        )
        XCTAssertTrue(sdk.cache.setLicense(License(
            licenseKey: "STORAGE-KEY-0001",
            deviceId: "storage-device-0001",
            activationId: "act-storage-0001",
            activatedAt: Date(),
            lastValidated: Date(),
            validation: validation
        )))
    }

    override func tearDown() {
        MockURLProtocol.reset()
        URLProtocol.unregisterClass(MockURLProtocol.self)
        super.tearDown()
    }

    func testAnUnreadableStoreIsUnknownNotInactiveAndNothingIsPurged() async throws {
        sdk.cache.simulatedReadFailures = [LicenseCache.Key.license]

        XCTAssertNil(sdk.currentLicense())
        XCTAssertTrue(sdk.isLicenseStorageUnavailable)
        guard case .pending = sdk.getStatus() else {
            return XCTFail("an unreadable store must not look inactive, got \(sdk.getStatus())")
        }
        XCTAssertTrue(sdk.stateSnapshot().licenseStorageUnavailable)

        do {
            try await sdk.heartbeat()
            XCTFail("expected a storage error")
        } catch let error as LicenseSeatError {
            XCTAssertEqual(error, .cacheError)
            XCTAssertEqual(LicenseSeatFailure(error).category, .storage)
            XCTAssertFalse(LicenseSeatFailure(error).isTerminal)
        }
        do {
            try await sdk.deactivate()
            XCTFail("expected a storage error")
        } catch let error as LicenseSeatError {
            XCTAssertEqual(error, .cacheError)
        }
        let restore = await sdk.restoreLicense()
        XCTAssertFalse(restore.restored)
        XCTAssertEqual(restore.error as? LicenseSeatError, .cacheError)

        // The Keychain unlocks: the activation is still there.
        sdk.cache.simulatedReadFailures = []
        XCTAssertEqual(sdk.currentLicense()?.licenseKey, "STORAGE-KEY-0001")
        XCTAssertFalse(sdk.isLicenseStorageUnavailable)
        guard case .active = sdk.getStatus() else {
            return XCTFail("expected the activation back, got \(sdk.getStatus())")
        }
    }

    func testAnUnreadableWatermarkIsNeverLowered() async throws {
        let high = Date().timeIntervalSince1970
        XCTAssertTrue(sdk.cache.setLastSeenTimestamp(high))

        sdk.cache.simulatedReadFailures = [LicenseCache.Key.lastSeenTimestamp]
        XCTAssertFalse(sdk.cache.setLastSeenTimestamp(high - 3_600))
        sdk.cache.simulatedReadFailures = []

        XCTAssertEqual(try XCTUnwrap(sdk.cache.getLastSeenTimestamp()), high, accuracy: 0.001)
    }

    func testLaunchWithAnUnreadableStoreReportsItAndKeepsTheActivation() async throws {
        sdk.shutdown()
        sdk = makeSDK()
        // Before the initialization task runs on the main actor.
        sdk.cache.simulatedReadFailures = [LicenseCache.Key.license]
        var events: [String] = []
        let subscription = sdk.on(.licenseStorageUnavailable) { _ in events.append("unavailable") }
        defer { subscription.cancel() }

        await sdk.waitForInitialization()
        let deadline = Date().addingTimeInterval(5)
        while events.isEmpty, Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        XCTAssertEqual(events, ["unavailable"])
        sdk.cache.simulatedReadFailures = []
        XCTAssertEqual(sdk.currentLicense()?.licenseKey, "STORAGE-KEY-0001")
    }
}
