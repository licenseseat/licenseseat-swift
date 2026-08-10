import XCTest
@testable import LicenseSeat

final class CanonicalJSONTests: LicenseSeatTestCase {
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

    func testCanonicalizesScalarKindsAndArrays() throws {
        let value: [String: Any] = [
            "array": [true, false, NSNull(), 1, 1.5, -0.0],
            "url": "https://example.com/a/b"
        ]
        let result = try CanonicalJSON.stringify(value)

        XCTAssertEqual(
            result,
            #"{"array":[true,false,null,1,1.5,0],"url":"https://example.com/a/b"}"#
        )
    }

    func testRejectsUnsupportedAndNonFiniteValues() {
        XCTAssertThrowsError(try CanonicalJSON.stringify(["date": Date()])) { error in
            guard case CanonicalJSONError.unsupportedType = error else {
                return XCTFail("Expected unsupportedType, got \(error)")
            }
        }
        for number in [Double.infinity, -Double.infinity, Double.nan] {
            XCTAssertThrowsError(
                try CanonicalJSON.stringify(["number": number])
            ) { error in
                guard case CanonicalJSONError.nonFiniteNumber = error else {
                    return XCTFail("Expected nonFiniteNumber, got \(error)")
                }
            }
        }
    }

    func testEnforcesDepthNodeKeyStringAndOutputBounds() {
        var nested: Any = 0
        for _ in 0..<21 {
            nested = [nested]
        }
        XCTAssertThrowsError(try CanonicalJSON.stringify(nested)) { error in
            guard case CanonicalJSONError.depthLimitExceeded = error else {
                return XCTFail("Expected depthLimitExceeded, got \(error)")
            }
        }

        XCTAssertThrowsError(
            try CanonicalJSON.stringify(Array(repeating: 0, count: 10_000))
        ) { error in
            guard case CanonicalJSONError.nodeLimitExceeded = error else {
                return XCTFail("Expected nodeLimitExceeded, got \(error)")
            }
        }
        XCTAssertThrowsError(
            try CanonicalJSON.stringify([String(repeating: "k", count: 257): 0])
        )
        XCTAssertThrowsError(
            try CanonicalJSON.stringify(["value": String(repeating: "x", count: 65_537)])
        )

        let maximumString = String(repeating: "x", count: 64 * 1_024)
        XCTAssertThrowsError(
            try CanonicalJSON.stringify(Array(repeating: maximumString, count: 16))
        ) { error in
            guard case CanonicalJSONError.sizeLimitExceeded = error else {
                return XCTFail("Expected sizeLimitExceeded, got \(error)")
            }
        }
    }

    func testCanonicalErrorDescriptionsRemainActionable() {
        XCTAssertNotNil(CanonicalJSONError.encodingFailed.errorDescription)
        XCTAssertNotNil(CanonicalJSONError.unsupportedType("Date").errorDescription)
        XCTAssertNotNil(CanonicalJSONError.depthLimitExceeded.errorDescription)
        XCTAssertNotNil(CanonicalJSONError.nodeLimitExceeded.errorDescription)
        XCTAssertNotNil(CanonicalJSONError.sizeLimitExceeded.errorDescription)
        XCTAssertNotNil(CanonicalJSONError.nonFiniteNumber.errorDescription)
    }
}
