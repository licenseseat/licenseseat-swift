import XCTest
@testable import LicenseSeatSDK

final class LicenseSeatSDKTests: XCTestCase {
    func testActivationPersistsInCache() async throws {
        throw XCTSkip("Activation requires live backend or mocking; skipped.")
    }
}
