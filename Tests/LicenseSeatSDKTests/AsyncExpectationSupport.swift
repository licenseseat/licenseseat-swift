import XCTest

/// Linux corelibs XCTest 6.2/6.3 can strand its internal async-teardown
/// expectation after the test body and synchronous cleanup have completed.
/// Every SDK test inherits this base so the Linux runner can distinguish that
/// upstream runner defect from a test, assertion, setup, or cleanup hang.
///
/// The marker is deliberately emitted from `tearDownWithError()`: XCTest has
/// already run the test body, recorded thrown/assertion failures, executed
/// teardown blocks, and called synchronous `tearDown()` at that point. The
/// final async override prevents subclasses from putting repository cleanup
/// after the marker. A timed-out process is therefore safe to accept only when
/// it emitted the exact zero-failure marker.
class LicenseSeatTestCase: XCTestCase {
    final override func tearDownWithError() throws {
        try super.tearDownWithError()

        #if os(Linux)
        let failureCount = testRun?.totalFailureCount ?? -1
        let marker = "__LICENSESEAT_XCTEST_BODY_AND_CLEANUP_COMPLETE__ " +
            "failures=\(failureCount)\n"
        FileHandle.standardError.write(Data(marker.utf8))
        #endif
    }

    final override func tearDown() async throws {
        try await super.tearDown()
    }
}

#if os(Linux)
/// Synchronization state for the Linux async-test bridge. The semaphore is the
/// happens-before boundary for `error`; the unchecked conformance is limited
/// to this test-only, single-writer/single-reader container.
private final class AsyncTestBridgeState: @unchecked Sendable {
    let completion = DispatchSemaphore(value: 0)
    var error: (any Error)?
}

/// A sendable container for XCTest's legacy, non-Sendable test closure type.
/// SwiftPM creates one case instance per invocation and the closure is called
/// exactly once, so transfer into the detached bridge task is exclusive.
private final class AsyncTestOperation: @unchecked Sendable {
    let body: () async throws -> Void

    init(body: @escaping () async throws -> Void) {
        self.body = body
    }
}

/// More-specific overload used by SwiftPM's generated Linux discovery for all
/// LicenseSeat test cases. Corelibs XCTest's generic `asyncTest` uses an
/// unstructured `Task` plus `XCTWaiter`; Swift 6.2 and 6.3 can strand that task
/// indefinitely. A detached task reliably enters the cooperative executor,
/// while pumping the runner's run loop allows `@MainActor` test methods to
/// execute on the required executor. Errors are rethrown into XCTest normally.
@available(macOS 12.0, *)
func asyncTest<T: LicenseSeatTestCase>(
    _ testClosureGenerator: @escaping (T) -> () async throws -> Void
) -> (T) -> () throws -> Void {
    return { testCase in
        let operation = AsyncTestOperation(body: testClosureGenerator(testCase))

        return {
            let state = AsyncTestBridgeState()
            Task.detached {
                do {
                    try await operation.body()
                } catch {
                    state.error = error
                }
                state.completion.signal()
            }

            while state.completion.wait(timeout: .now()) != .success {
                _ = RunLoop.current.run(
                    mode: .default,
                    before: Date(timeIntervalSinceNow: 0.01)
                )
            }

            if let error = state.error {
                throw error
            }
        }
    }
}
#endif

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
extension MachineFileTests: @unchecked Sendable {}
extension ReleasesTests: @unchecked Sendable {}
extension OfflineValidationTests: @unchecked Sendable {}
extension PublicAPISurfaceTests: @unchecked Sendable {}
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
