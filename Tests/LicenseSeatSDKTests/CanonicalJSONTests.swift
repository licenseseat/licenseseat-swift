import XCTest
@testable import LicenseSeat

final class CanonicalJSONTests: XCTestCase {
    func testCanonicalizationSortsKeysRecursively() throws {
        let obj: [String: Any] = [
            "b": 1,
            "a": [
                "d": 1,
                "c": 2
            ]
        ]
        let string1 = try CanonicalJSON.stringify(obj)
        let string2 = try CanonicalJSON.stringify(obj)
        XCTAssertEqual(string1, string2)
        XCTAssertTrue(string1.contains("\"a\""))
        // Ensure order a then b
        let rangeA = string1.range(of: "\"a\"")!
        let rangeB = string1.range(of: "\"b\"")!
        XCTAssertLessThan(rangeA.lowerBound, rangeB.lowerBound)
    }
} 