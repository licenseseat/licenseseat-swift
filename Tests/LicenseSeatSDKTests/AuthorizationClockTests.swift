//
//  AuthorizationClockTests.swift
//  LicenseSeatSDKTests
//
//  The in-process monotonic floor under the authorization clock (#12):
//  rollback cannot revive a grant, and no legitimate clock behaviour
//  (sleep, NTP corrections, forward errors, relaunch) can lock anyone out.
//

import XCTest
@testable import LicenseSeat

/// A hand-driven wall clock and monotonic clock.
@MainActor
final class ManualClockSource {
    var wall: TimeInterval
    var monotonic: UInt64?

    init(
        wall: TimeInterval = Date().timeIntervalSince1970,
        monotonic: UInt64? = 5_000_000_000
    ) {
        self.wall = wall
        self.monotonic = monotonic
    }

    /// Real time passes: both clocks move together.
    func elapse(_ seconds: TimeInterval) {
        wall += seconds
        monotonic = monotonic.map { $0 + UInt64(seconds * 1_000_000_000) }
    }

    /// Real time passes while the wall clock is pinned or moved separately.
    func elapseMonotonicOnly(_ seconds: TimeInterval) {
        monotonic = monotonic.map { $0 + UInt64(seconds * 1_000_000_000) }
    }

    func makeClock() -> AuthorizationClock {
        AuthorizationClock(
            wallClock: { [unowned self] in self.wall },
            monotonicClock: { [unowned self] in self.monotonic }
        )
    }
}

@MainActor
final class AuthorizationClockTests: LicenseSeatTestCase {
    private let base: TimeInterval = 1_800_000_000

    func testMatchesTheWallClockWhileTheWallClockIsHonest() {
        let source = ManualClockSource(wall: base)
        let clock = source.makeClock()

        XCTAssertEqual(clock.now().timeIntervalSince1970, base)
        source.elapse(3_600)
        XCTAssertEqual(clock.now().timeIntervalSince1970, base + 3_600)
        XCTAssertEqual(clock.wallClockLag(), 0)
    }

    func testWallClockRolledBackInProcessIsRaisedToTheMonotonicFloor() {
        let source = ManualClockSource(wall: base)
        let clock = source.makeClock()

        source.elapse(7_200)
        source.wall = base + 1_800 // wound back 90 minutes

        XCTAssertEqual(clock.now().timeIntervalSince1970, base + 7_200)
        XCTAssertEqual(clock.wallClockLag(), 5_400)
    }

    func testSleepNeverLagsTheWallClock() {
        // The system source counts through sleep, so the floor tracks the
        // wall clock; even a source that did not would only fall behind it.
        let source = ManualClockSource(wall: base)
        let clock = source.makeClock()

        source.elapse(8 * 3_600)
        XCTAssertEqual(clock.now().timeIntervalSince1970, base + 8 * 3_600)

        source.wall += 8 * 3_600 // a suspend the monotonic source missed
        XCTAssertEqual(clock.now().timeIntervalSince1970, base + 16 * 3_600)
        XCTAssertEqual(clock.wallClockLag(), 0)
    }

    func testForwardClockErrorCorrectedByNTPDoesNotStickInTheFuture() {
        // A transiently wrong future clock must not leave the process living
        // in the future after NTP corrects it; that would be a lockout.
        let source = ManualClockSource(wall: base)
        let clock = source.makeClock()

        source.elapse(10)
        source.wall = base + 365 * 86_400
        XCTAssertEqual(clock.now().timeIntervalSince1970, base + 365 * 86_400)

        source.elapse(10)
        source.wall = base + 20
        XCTAssertEqual(clock.now().timeIntervalSince1970, base + 20)
    }

    func testAnchorReBaselinesAndMayLowerTheFloor() {
        // Started with a clock that was an hour fast, then NTP corrected it.
        let source = ManualClockSource(wall: base + 3_600)
        let clock = source.makeClock()
        source.elapse(60)
        source.wall = base + 60
        XCTAssertEqual(clock.now().timeIntervalSince1970, base + 3_660)

        clock.anchor() // authoritative online success

        XCTAssertEqual(clock.now().timeIntervalSince1970, base + 60)
        XCTAssertEqual(clock.wallClockLag(), 0)
    }

    func testUnavailableOrRegressingMonotonicSourceFallsBackToTheWallClock() {
        let missing = ManualClockSource(wall: base, monotonic: nil)
        let missingClock = missing.makeClock()
        missing.wall = base - 3_600
        XCTAssertEqual(missingClock.now().timeIntervalSince1970, base - 3_600)

        let regressing = ManualClockSource(wall: base, monotonic: 10_000_000_000)
        let regressingClock = regressing.makeClock()
        regressing.monotonic = 1
        regressing.wall = base - 3_600
        XCTAssertEqual(regressingClock.now().timeIntervalSince1970, base - 3_600)
    }

    func testSystemMonotonicSourceIsAvailableAndNonDecreasing() throws {
        let first = try XCTUnwrap(AuthorizationClock.systemMonotonicNanoseconds())
        let second = try XCTUnwrap(AuthorizationClock.systemMonotonicNanoseconds())
        XCTAssertGreaterThanOrEqual(second, first)

        let clock = AuthorizationClock()
        XCTAssertEqual(
            clock.now().timeIntervalSince1970,
            Date().timeIntervalSince1970,
            accuracy: 5
        )
    }

    // MARK: - SDK wiring

    func testOnlineAnchorAndResetSemantics() throws {
        let sdk = LicenseSeat(
            config: LicenseSeatConfig(
                productSlug: "clock-app",
                storagePrefix: "authorization_clock_test_\(UUID().uuidString)_"
            )
        )
        defer { sdk.reset() }
        let source = ManualClockSource()
        sdk.authorizationClock = source.makeClock()

        source.elapse(3_600)
        source.wall -= 3_600
        XCTAssertEqual(sdk.authorizationClock.wallClockLag(), 3_600)

        // reset()/clear() preserve the floor exactly as they preserve the
        // persisted watermark.
        sdk.reset()
        XCTAssertEqual(sdk.authorizationClock.wallClockLag(), 3_600)

        // Authoritative online success re-anchors both.
        XCTAssertTrue(sdk.anchorAuthoritativeTime(Date(timeIntervalSince1970: source.wall)))
        XCTAssertEqual(sdk.authorizationClock.wallClockLag(), 0)
        XCTAssertEqual(
            try XCTUnwrap(sdk.lastSeenTimestamp()).timeIntervalSince1970,
            source.wall,
            accuracy: 0.001
        )
    }
}
