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
        // The clock-rollback watermark deliberately survives clear(), like
        // the installation identifier: a reset combined with a clock rollback
        // and re-imported artifact files must not extend an offline window.
        XCTAssertEqual(cache.getLastSeenTimestamp() ?? 0, timestamp, accuracy: 0.001)
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

    func testClearPreservesClockRollbackWatermark() {
        XCTAssertTrue(cache.setLastSeenTimestamp(1_700_000_000))

        cache.clear()

        XCTAssertEqual(
            cache.getLastSeenTimestamp(),
            1_700_000_000,
            "clear/reset must preserve the rollback watermark like the installation identifier"
        )
    }

    func testAuthoritativeAnchorMayLowerWatermark() {
        // A transiently future-set clock poisoned the ratcheting watermark.
        XCTAssertTrue(cache.setLastSeenTimestamp(4_102_444_800))

        XCTAssertTrue(cache.anchorLastSeenTimestamp(1_700_000_000))
        XCTAssertEqual(cache.getLastSeenTimestamp(), 1_700_000_000)

        XCTAssertFalse(cache.anchorLastSeenTimestamp(0))
        XCTAssertFalse(cache.anchorLastSeenTimestamp(-5))
        XCTAssertEqual(cache.getLastSeenTimestamp(), 1_700_000_000)

        // The offline ratchet still refuses to move backward after an anchor.
        XCTAssertTrue(cache.setLastSeenTimestamp(100))
        XCTAssertEqual(cache.getLastSeenTimestamp(), 1_700_000_000)
    }

    func testAnchorRemovesStaleLegacyWatermarkSoRatchetCannotRepoisonIt() {
        // The 0.4.x plaintext slot may still hold the poisoned future value.
        defaults.set(4_102_444_800.0, forKey: prefix + "last_seen_ts")

        XCTAssertTrue(cache.anchorLastSeenTimestamp(1_700_000_000))
        XCTAssertEqual(cache.getLastSeenTimestamp(), 1_700_000_000)

        // A later ratcheting write must not resurrect the stale legacy value.
        XCTAssertTrue(cache.setLastSeenTimestamp(1_700_000_100))
        XCTAssertEqual(cache.getLastSeenTimestamp(), 1_700_000_100)
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
