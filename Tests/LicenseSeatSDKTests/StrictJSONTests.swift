import Foundation
import XCTest
@testable import LicenseSeat

final class StrictJSONTests: LicenseSeatTestCase {
    func testAcceptsOneBoundedNestedJSONDocument() throws {
        let data = Data(
            #"{"array":[true,false,null,1,-2.5,3e2],"nested":{"value":"ok"}}"#
                .utf8
        )

        XCTAssertNoThrow(try StrictJSON.validate(data, limits: .api))
    }

    func testRejectsDuplicateKeysAtEveryDepth() {
        for document in [
            #"{"key":1,"key":2}"#,
            #"{"outer":{"key":1,"key":2}}"#,
            #"{"outer":[{"key":1,"key":2}]}"#
        ] {
            XCTAssertThrowsError(
                try StrictJSON.validate(Data(document.utf8), limits: .api)
            ) { error in
                XCTAssertEqual(error as? StrictJSONError, .duplicateKey)
            }
        }
    }

    func testRejectsEscapeEquivalentDuplicateKeys() {
        let document = #"{"\u0061":1,"a":2}"#

        XCTAssertThrowsError(
            try StrictJSON.validate(Data(document.utf8), limits: .api)
        ) { error in
            XCTAssertEqual(error as? StrictJSONError, .duplicateKey)
        }
    }

    func testRejectsTrailingDataAndInvalidNumberForms() {
        for document in [
            #"{}{}"#,
            #"{"value":01}"#,
            #"{"value":1.}"#,
            #"{"value":1e}"#,
            #"{"value":"\x"}"#,
            #"{"value":true,}"#,
            #"[1 2]"#
        ] {
            XCTAssertThrowsError(
                try StrictJSON.validate(Data(document.utf8), limits: .api)
            )
        }
    }

    func testRejectsNonFiniteNumericMagnitude() {
        XCTAssertThrowsError(
            try StrictJSON.validate(
                Data(#"{"value":1e9999}"#.utf8),
                limits: .api
            )
        ) { error in
            XCTAssertEqual(error as? StrictJSONError, .nonFiniteNumber)
        }
    }

    func testRejectsDuplicateKeyBeforeModelDecodingCanChooseOne() {
        struct Payload: Decodable {
            let authority: Bool
        }
        let data = Data(#"{"authority":false,"authority":true}"#.utf8)

        // Foundation itself accepts one duplicate value. The security
        // boundary must reject the ambiguous document first.
        XCTAssertNotNil(try? JSONDecoder().decode(Payload.self, from: data))
        XCTAssertThrowsError(
            try StrictJSON.validate(data, limits: .api)
        ) { error in
            XCTAssertEqual(error as? StrictJSONError, .duplicateKey)
        }
    }

    func testEnforcesDepthNodeStringAndDocumentLimits() {
        let tiny = StrictJSON.Limits(
            maxBytes: 64,
            maxDepth: 2,
            maxNodes: 4,
            maxKeyBytes: 8,
            maxStringBytes: 4,
            maxNumberBytes: 8
        )

        XCTAssertThrowsError(
            try StrictJSON.validate(Data(#"[[[0]]]"#.utf8), limits: tiny)
        ) { error in
            XCTAssertEqual(
                error as? StrictJSONError,
                .depthLimitExceeded
            )
        }
        XCTAssertThrowsError(
            try StrictJSON.validate(Data(#"[0,1,2,3]"#.utf8), limits: tiny)
        ) { error in
            XCTAssertEqual(error as? StrictJSONError, .nodeLimitExceeded)
        }
        XCTAssertThrowsError(
            try StrictJSON.validate(
                Data(#"{"key":"12345"}"#.utf8),
                limits: tiny
            )
        ) { error in
            XCTAssertEqual(error as? StrictJSONError, .sizeLimitExceeded)
        }
        XCTAssertThrowsError(
            try StrictJSON.validate(
                Data(#"{"123456789":0}"#.utf8),
                limits: tiny
            )
        ) { error in
            XCTAssertEqual(error as? StrictJSONError, .sizeLimitExceeded)
        }
        XCTAssertThrowsError(
            try StrictJSON.validate(
                Data(#"{"value":123456789}"#.utf8),
                limits: tiny
            )
        ) { error in
            XCTAssertEqual(error as? StrictJSONError, .sizeLimitExceeded)
        }
        XCTAssertThrowsError(
            try StrictJSON.validate(
                Data(String(repeating: " ", count: 65).utf8),
                limits: tiny
            )
        ) { error in
            XCTAssertEqual(error as? StrictJSONError, .sizeLimitExceeded)
        }
    }

    func testRejectsInvalidUTF8AndBrokenUnicodeEscapesAsSyntax() {
        let invalidUTF8 = Data([
            0x7B, 0x22, 0x6B, 0x22, 0x3A, 0x22, 0xFF, 0x22, 0x7D
        ])
        for data in [invalidUTF8, Data(#"{"key":"\u12xz"}"#.utf8)] {
            XCTAssertThrowsError(try StrictJSON.validate(data, limits: .api)) { error in
                XCTAssertEqual(error as? StrictJSONError, .invalidSyntax)
            }
        }
    }
}
