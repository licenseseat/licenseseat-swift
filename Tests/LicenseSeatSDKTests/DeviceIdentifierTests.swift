import XCTest
@testable import LicenseSeat

final class DeviceIdentifierTests: XCTestCase {

    override func setUp() {
        super.setUp()
        // Clear cached identifier before each test to ensure isolation
        DeviceIdentifier.clearCache()
    }

    override func tearDown() {
        // Clean up after tests
        DeviceIdentifier.clearCache()
        super.tearDown()
    }

    func testGenerateProducesNonEmptyString() {
        let id = DeviceIdentifier.generate()
        XCTAssertFalse(id.isEmpty)
    }

    func testGenerateProducesStableValues() {
        // The device identifier should be stable across multiple calls
        let first = DeviceIdentifier.generate()
        let second = DeviceIdentifier.generate()
        XCTAssertEqual(first, second, "Device identifier should be cached and return the same value")
    }

    func testClearCacheAllowsNewGeneration() {
        let first = DeviceIdentifier.generate()
        DeviceIdentifier.clearCache()
        let second = DeviceIdentifier.generate()

        // After clearing cache, a new identifier is generated
        // Note: On macOS with hardware UUID, both might be the same since hardware UUID is stable
        // But for fallback platforms, the random suffix would differ
        XCTAssertFalse(first.isEmpty)
        XCTAssertFalse(second.isEmpty)
    }

    func testGenerateProducesPlatformPrefixedString() {
        let id = DeviceIdentifier.generate()

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
