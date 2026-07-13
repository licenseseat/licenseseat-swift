import Foundation
import XCTest
@testable import LicenseSeat

final class LicenseCacheTests: LicenseSeatTestCase {
    private var prefix: String!
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var cache: LicenseCache!

    override func setUp() {
        super.setUp()
        prefix = "license_cache_test_\(UUID().uuidString)_"
        suiteName = "LicenseSeatTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        cache = LicenseCache(prefix: prefix, userDefaults: defaults)
        cache.clear()
    }

    override func tearDown() {
        cache.clear()
        defaults.removePersistentDomain(forName: suiteName)
        cache = nil
        defaults = nil
        suiteName = nil
        prefix = nil
        super.tearDown()
    }

    func testLicenseRoundTripAndClear() {
        let license = makeLicense()

        cache.setLicense(license)

        XCTAssertEqual(cache.getLicense(), license)
        #if canImport(Security)
        XCTAssertNil(defaults.data(forKey: prefix + "license"))
        #endif

        cache.clearLicense()
        XCTAssertNil(cache.getLicense())
    }

    func testMigratesLegacyPlaintextLicenseWithoutLosingIt() throws {
        let license = makeLicense()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        defaults.set(try encoder.encode(license), forKey: prefix + "license")

        XCTAssertEqual(cache.getLicense(), license)
        #if canImport(Security)
        XCTAssertNil(defaults.data(forKey: prefix + "license"))
        #endif

        // A second cache instance proves the value came from protected storage,
        // not merely from the migration call's in-memory return value.
        let reloadedCache = LicenseCache(prefix: prefix, userDefaults: defaults)
        XCTAssertEqual(reloadedCache.getLicense(), license)
    }

    func testOfflineTokenSigningKeysAndClockStateRoundTrip() {
        let token = makeOfflineToken()
        let timestamp = Date().timeIntervalSince1970

        cache.setOfflineToken(token)
        cache.setPublicKey("kid-1", "public-key-material")
        cache.setLastSeenTimestamp(timestamp)

        XCTAssertEqual(cache.getOfflineToken(), token)
        XCTAssertEqual(cache.getPublicKey("kid-1"), "public-key-material")
        XCTAssertEqual(cache.getLastSeenTimestamp() ?? 0, timestamp, accuracy: 0.001)

        #if canImport(Security)
        XCTAssertNil(defaults.data(forKey: prefix + "offline_token"))
        XCTAssertNil(defaults.data(forKey: prefix + "public_keys"))
        XCTAssertNil(defaults.object(forKey: prefix + "last_seen_ts"))
        #endif

        cache.clear()
        XCTAssertNil(cache.getOfflineToken())
        XCTAssertNil(cache.getPublicKey("kid-1"))
        XCTAssertNil(cache.getLastSeenTimestamp())
    }

    func testMigratesLegacyClockTimestamp() {
        let timestamp = Date().timeIntervalSince1970
        defaults.set(timestamp, forKey: prefix + "last_seen_ts")

        XCTAssertEqual(cache.getLastSeenTimestamp() ?? 0, timestamp, accuracy: 0.001)
        #if canImport(Security)
        XCTAssertNil(defaults.object(forKey: prefix + "last_seen_ts"))
        #endif
    }

    func testClockWatermarkNeverMovesBackward() {
        XCTAssertTrue(cache.setLastSeenTimestamp(2_000))
        XCTAssertTrue(cache.setLastSeenTimestamp(1_000))

        XCTAssertEqual(cache.getLastSeenTimestamp(), 2_000)
    }

    func testClearPreservesOtherValuesSharingTheStoragePrefix() {
        let installationIdentifierKey = prefix + "device_identifier"
        defaults.set("stable-installation", forKey: installationIdentifierKey)
        XCTAssertTrue(cache.setLicense(makeLicense()))

        cache.clear()

        XCTAssertNil(cache.getLicense())
        XCTAssertEqual(
            defaults.string(forKey: installationIdentifierKey),
            "stable-installation"
        )
    }

    private func makeLicense() -> License {
        License(
            licenseKey: "TEST-LICENSE",
            deviceId: "test-device",
            activationId: "123",
            activatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            lastValidated: Date(timeIntervalSince1970: 1_700_000_100)
        )
    }

    private func makeOfflineToken() -> OfflineTokenResponse {
        let payload = OfflineTokenResponse.TokenPayload(
            schemaVersion: 1,
            licenseKey: "TEST-LICENSE",
            productSlug: "test-product",
            planKey: "pro",
            mode: "hardware_locked",
            seatLimit: 1,
            deviceId: "test-device",
            iat: 1_700_000_000,
            exp: 1_700_086_400,
            nbf: 1_700_000_000,
            licenseExpiresAt: nil,
            kid: "kid-1",
            entitlements: [],
            metadata: nil
        )
        return OfflineTokenResponse(
            object: "offline_token",
            token: payload,
            signature: .init(algorithm: "Ed25519", keyId: "kid-1", value: "signature"),
            canonical: "{}"
        )
    }
}
