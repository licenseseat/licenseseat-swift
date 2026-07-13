import XCTest

// Swift 6.2's generated Linux XCTest discovery wrappers send each test-case
// instance into its @MainActor test method. XCTest creates one instance per
// invocation and does not concurrently access it, so this test-only conformance
// makes that runner guarantee explicit until corelibs XCTest's nonsending fix
// is available in the minimum supported toolchain.
extension APIClientTests: @unchecked Sendable {}
extension AutoValidationTests: @unchecked Sendable {}
#if canImport(Combine)
extension CombineDemandTests: @unchecked Sendable {}
#endif
extension EntitlementTests: @unchecked Sendable {}
extension HeartbeatTimerTests: @unchecked Sendable {}
extension LicenseSeatSDKTests: @unchecked Sendable {}
extension LicenseSeatStoreTests: @unchecked Sendable {}
extension OfflineValidationTests: @unchecked Sendable {}
extension TelemetryAPIIntegrationTests: @unchecked Sendable {}

/// Cross-platform async expectation helper that avoids sending an
/// actor-isolated `XCTestCase` through corelibs XCTest's pre-Swift-6.3
/// instance API.
@MainActor
func assertFulfillment(
    of expectations: [XCTestExpectation],
    timeout: TimeInterval,
    enforceOrder: Bool = false,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    let result = await XCTWaiter.fulfillment(
        of: expectations,
        timeout: timeout,
        enforceOrder: enforceOrder
    )

    XCTAssertEqual(
        result,
        .completed,
        "Asynchronous expectations did not complete: \(result)",
        file: file,
        line: line
    )
}
