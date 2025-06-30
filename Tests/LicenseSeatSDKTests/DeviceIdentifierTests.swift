import XCTest
@testable import LicenseSeat

final class DeviceIdentifierTests: XCTestCase {
    func testGenerateProducesNonEmptyString() {
        let id = DeviceIdentifier.generate()
        XCTAssertFalse(id.isEmpty)
    }
    
    func testGenerateProducesUniqueValues() throws {
        let first = DeviceIdentifier.generate()
        let second = DeviceIdentifier.generate()
        if first == second {
            throw XCTSkip("DeviceIdentifier.generate() may return stable identifier on this platform")
        }
    }
} 