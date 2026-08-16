//
//  PublicAPISurfaceTests.swift
//  LicenseSeatSDKTests
//
//  Compiled against the module's public interface only. A member that loses
//  `public` breaks this file at build time instead of silently narrowing the
//  supported API.
//

import XCTest
import LicenseSeat

@MainActor
final class PublicAPISurfaceTests: LicenseSeatTestCase {
    private static let testProductSlug = "test-app"

    func testBackgroundTaskControlIsPubliclyAvailable() async {
        var config = LicenseSeatConfig(
            apiKey: "public-surface-key",
            productSlug: Self.testProductSlug,
            storagePrefix: "public_surface_\(UUID().uuidString)_",
            autoValidateInterval: 900,
            heartbeatInterval: 900
        )
        config.requestTimeout = 15
        config.appVersion = "1.2.3"
        config.appBuild = "77"
        config.offlineFallbackEnabled = false

        let seat = LicenseSeat(config: config)
        defer { seat.reset() }

        XCTAssertFalse(seat.isAutoValidating)
        XCTAssertNil(seat.nextAutoValidationAt)
        XCTAssertNil(seat.lastSeenTimestamp())

        seat.startAutoValidation(licenseKey: "PUBLIC-SURFACE-LICENSE")
        seat.startHeartbeat()

        XCTAssertTrue(seat.isAutoValidating)
        XCTAssertNotNil(seat.nextAutoValidationAt)

        seat.stopHeartbeat()
        seat.stopAutoValidation()

        XCTAssertFalse(seat.isAutoValidating)
        XCTAssertNil(seat.nextAutoValidationAt)
    }

    func testConfigureReportsWhetherItWasApplied() async {
        let store = LicenseSeatStore(
            config: LicenseSeatConfig(
                storagePrefix: "public_surface_store_\(UUID().uuidString)_",
                autoValidateInterval: 0,
                heartbeatInterval: 0
            )
        )
        defer { store.reset() }

        let applied: Bool = store.configure(
            apiKey: "public-surface-key",
            productSlug: Self.testProductSlug,
            force: true
        ) { config in
            config.storagePrefix = "public_surface_store_\(UUID().uuidString)_"
            config.autoValidateInterval = 0
            config.heartbeatInterval = 0
        }
        XCTAssertTrue(applied)

        let ignored: Bool = store.configure(
            apiKey: "public-surface-replacement",
            productSlug: Self.testProductSlug
        )
        XCTAssertFalse(ignored)
        XCTAssertEqual(store.seat?.config.apiKey, "public-surface-key")
    }
}
