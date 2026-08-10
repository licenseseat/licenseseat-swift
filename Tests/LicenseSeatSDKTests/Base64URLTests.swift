import XCTest
@testable import LicenseSeat

final class Base64URLTests: LicenseSeatTestCase {
    func testRoundTripUsesUnpaddedURLSafeEncoding() throws {
        let data = Data([0xfb, 0xff, 0xef])
        let encoded = Base64URL.encode(data)

        XCTAssertEqual(encoded, "-__v")
        XCTAssertEqual(try Base64URL.decode(encoded), data)
    }

    func testDecodesCanonicalPaddedBase64FromRailsAPI() throws {
        XCTAssertEqual(try Base64URL.decode("+//v"), Data([0xfb, 0xff, 0xef]))
        XCTAssertEqual(try Base64URL.decode("AQ=="), Data([1]))
    }

    func testRejectsMixedAlphabetMalformedPaddingAndWhitespace() {
        for malformed in [
            "+__v", "-__v=", "AQ=", "AQ===", "-__v\n", "A", "", "AR==", "AR"
        ] {
            XCTAssertThrowsError(try Base64URL.decode(malformed), malformed)
        }
    }
}
