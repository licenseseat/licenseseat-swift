import XCTest
@testable import LicenseSeat

final class DeviceIdentifierTests: XCTestCase {
    private var defaults: UserDefaults!
    private var keychainServiceSuffix: String!

    override func setUp() {
        super.setUp()
        let namespace = UUID().uuidString
        defaults = UserDefaults(suiteName: "DeviceIdentifierTests.\(namespace)")!
        keychainServiceSuffix = ".tests.\(namespace)"
        clearIdentifier()
    }

    override func tearDown() {
        clearIdentifier()
        defaults = nil
        keychainServiceSuffix = nil
        super.tearDown()
    }

    private func generateIdentifier() -> String {
        DeviceIdentifier.generate(
            userDefaults: defaults,
            keychainServiceSuffix: keychainServiceSuffix
        )
    }

    private func clearIdentifier() {
        DeviceIdentifier.clearCache(
            userDefaults: defaults,
            keychainServiceSuffix: keychainServiceSuffix
        )
    }

    func testGenerateProducesNonEmptyString() {
        let id = generateIdentifier()
        XCTAssertFalse(id.isEmpty)
    }

    func testGenerateProducesStableValues() {
        // The device identifier should be stable across multiple calls
        let first = generateIdentifier()
        let second = generateIdentifier()
        XCTAssertEqual(first, second, "Device identifier should be cached and return the same value")
    }

    func testClearCacheAllowsNewGeneration() {
        let first = generateIdentifier()
        clearIdentifier()
        let second = generateIdentifier()

        XCTAssertNotEqual(first, second)
    }

    func testMigratesLegacyIdentifierWithoutChangingSeatIdentity() {
        let legacyIdentifier = "mac-legacy-installation"
        defaults.set(
            legacyIdentifier,
            forKey: "licenseseat_device_identifier"
        )

        XCTAssertEqual(generateIdentifier(), legacyIdentifier)
        XCTAssertEqual(generateIdentifier(), legacyIdentifier)

        #if canImport(Security)
        XCTAssertNil(
            defaults.string(forKey: "licenseseat_device_identifier"),
            "Plaintext should be removed only after Keychain migration succeeds"
        )
        #endif
    }

    func testEmptyLegacyIdentifierIsReplacedWithUsableIdentity() {
        defaults.set("", forKey: "licenseseat_device_identifier")

        let identifier = generateIdentifier()

        XCTAssertFalse(identifier.isEmpty)
        XCTAssertNotEqual(identifier, "")
        XCTAssertEqual(generateIdentifier(), identifier)
    }

    func testLicenseResetDoesNotRotateInstallationIdentityOrConsumeASeat() {
        let first = generateIdentifier()
        let licenseCache = LicenseCache(prefix: "licenseseat_", userDefaults: defaults)

        licenseCache.clear()

        XCTAssertEqual(generateIdentifier(), first)
    }

    func testGenerateProducesPlatformPrefixedString() {
        let id = generateIdentifier()

        #if os(iOS) || os(tvOS)
        XCTAssertTrue(id.hasPrefix("ios-"), "iOS device identifier should have 'ios-' prefix")
        #elseif os(watchOS)
        XCTAssertTrue(id.hasPrefix("watch-"), "watchOS device identifier should have 'watch-' prefix")
        #elseif os(macOS)
        XCTAssertTrue(id.hasPrefix("mac-"), "macOS device identifier should have 'mac-' prefix")
        #else
        XCTAssertTrue(id.hasPrefix("swift-"), "Unknown platform device identifier should have 'swift-' prefix")
        #endif
    }
}
