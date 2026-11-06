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

    /// A clock that has already seen an authoritative online success whose
    /// server time equalled the current (accurate) wall clock.
    func makeTrustedClock() -> AuthorizationClock {
        let clock = makeClock()
        clock.anchor(trustedTime: Date(timeIntervalSince1970: wall))
        return clock
    }
}

// Linux discovery: every test method of a @MainActor suite must be async.
@MainActor
final class AuthorizationClockTests: LicenseSeatTestCase {
    private let base: TimeInterval = 1_800_000_000

    func testMatchesTheWallClockWhileTheWallClockIsHonest() async {
        let source = ManualClockSource(wall: base)
        let clock = source.makeTrustedClock()

        XCTAssertEqual(clock.now().timeIntervalSince1970, base)
        source.elapse(3_600)
        XCTAssertEqual(clock.now().timeIntervalSince1970, base + 3_600)
        XCTAssertEqual(clock.wallClockLag(), 0)
    }

    func testWallClockRolledBackAfterATrustedSampleIsRaisedToTheFloor() async {
        let source = ManualClockSource(wall: base)
        let clock = source.makeTrustedClock()

        source.elapse(7_200)
        source.wall = base + 1_800 // wound back 90 minutes

        XCTAssertEqual(clock.now().timeIntervalSince1970, base + 7_200)
        XCTAssertEqual(clock.wallClockLag(), 5_400)
    }

    func testWithoutATrustedSampleTheWallClockIsUsedAsIs() async {
        // R2-1: a local reading is never a trusted epoch. A fast clock that
        // is corrected and a rollback look identical; flooring on either
        // would lock out the first. Cold sessions rely on the watermark.
        let source = ManualClockSource(wall: base + 360) // six minutes fast
        let clock = source.makeClock()
        source.elapse(60)
        source.wall = base + 60 // corrected by NTP

        XCTAssertFalse(clock.hasTrustedBaseline)
        XCTAssertEqual(clock.now(tolerance: 300).timeIntervalSince1970, base + 60)
        source.elapse(3_600)
        source.wall = base // a rollback in a cold session is not floored
        XCTAssertEqual(clock.now(tolerance: 300).timeIntervalSince1970, base)
    }

    func testSleepNeverLagsTheWallClock() async {
        let source = ManualClockSource(wall: base)
        let clock = source.makeTrustedClock()

        source.elapse(8 * 3_600)
        XCTAssertEqual(clock.now().timeIntervalSince1970, base + 8 * 3_600)

        source.wall += 8 * 3_600 // a suspend the monotonic source missed
        XCTAssertEqual(clock.now().timeIntervalSince1970, base + 16 * 3_600)
        XCTAssertEqual(clock.wallClockLag(), 0)
    }

    func testForwardClockErrorCorrectedByNTPDoesNotStickInTheFuture() async {
        let source = ManualClockSource(wall: base)
        let clock = source.makeTrustedClock()

        source.elapse(10)
        source.wall = base + 365 * 86_400
        XCTAssertEqual(clock.now().timeIntervalSince1970, base + 365 * 86_400)

        source.elapse(10)
        source.wall = base + 20
        XCTAssertEqual(clock.now().timeIntervalSince1970, base + 20)
    }

    func testRollbackWithinToleranceOfTheTrustedFloorIsTheDocumentedWindow() async {
        // R2-4: the skew allowance applies to the floor too. Rolling back by
        // less than the tolerance is accepted; by more, it is floored.
        let source = ManualClockSource(wall: base)
        let clock = source.makeTrustedClock()
        source.elapse(1_860)

        source.wall = base + 1_860 - 120 // 2 minutes back
        XCTAssertEqual(clock.now(tolerance: 300).timeIntervalSince1970, base + 1_740)
        source.wall = base + 1_860 - 3_600 // an hour back
        XCTAssertEqual(clock.now(tolerance: 300).timeIntervalSince1970, base + 1_860 - 300)
    }

    func testTrustedServerTimeSetsTheFloorAndAMissingDateKeepsIt() async {
        let source = ManualClockSource(wall: base - 7_200) // two hours slow
        let clock = source.makeClock()

        clock.anchor(trustedTime: Date(timeIntervalSince1970: base))
        source.elapse(10)
        XCTAssertEqual(clock.now().timeIntervalSince1970, base + 10)
        XCTAssertEqual(clock.wallTime().timeIntervalSince1970, base - 7_190)

        // A later online success without a usable Date keeps the baseline.
        clock.anchor(trustedTime: nil)
        clock.anchor(trustedTime: Date(timeIntervalSince1970: -.infinity))
        source.elapse(10)
        XCTAssertEqual(clock.now().timeIntervalSince1970, base + 20)

        // An older sample never lowers it; a newer one raises it.
        clock.anchor(trustedTime: Date(timeIntervalSince1970: source.wall))
        XCTAssertEqual(clock.now().timeIntervalSince1970, base + 20)
        clock.anchor(trustedTime: Date(timeIntervalSince1970: base + 600))
        XCTAssertEqual(clock.now().timeIntervalSince1970, base + 600)
    }

    func testAnImplausibleServerDateIsIgnored() async {
        // R2-1: a proxy stamping 2099 must not expire valid grants.
        let source = ManualClockSource(wall: base)
        let clock = source.makeClock()

        clock.anchor(trustedTime: Date(timeIntervalSince1970: 4_070_908_800)) // 2099
        XCTAssertFalse(clock.hasTrustedBaseline)
        XCTAssertEqual(clock.now().timeIntervalSince1970, base)

        clock.anchor(trustedTime: Date(timeIntervalSince1970: base + AuthorizationClock.maximumTrustedLead + 1))
        XCTAssertFalse(clock.hasTrustedBaseline)
        clock.anchor(trustedTime: Date(timeIntervalSince1970: base + 3_600))
        XCTAssertTrue(clock.hasTrustedBaseline)
    }

    func testSnapshotSamplesTheWallClockOnce() async {
        let source = ManualClockSource(wall: base)
        let clock = source.makeClock()
        clock.anchor(trustedTime: Date(timeIntervalSince1970: base + 3_600))

        let instant = clock.snapshot(tolerance: 300)
        source.wall = base + 7_200 // the clock moves after sampling

        XCTAssertEqual(instant.wall.timeIntervalSince1970, base)
        XCTAssertEqual(instant.effective.timeIntervalSince1970, base + 3_300)
    }

    func testClocksAreSharedPerStorageScope() async {
        let scope = "clock_scope_\(UUID().uuidString)"
        XCTAssertTrue(AuthorizationClock.shared(scope: scope) === AuthorizationClock.shared(scope: scope))
        XCTAssertFalse(AuthorizationClock.shared(scope: scope) === AuthorizationClock.shared(scope: scope + "x"))

        // R2-3: canonically equivalent but byte-different prefixes have
        // separate caches, so they must not share a clock.
        let composed = "caf\u{00E9}_\(UUID().uuidString)"
        let decomposed = composed.replacingOccurrences(of: "\u{00E9}", with: "e\u{0301}")
        XCTAssertEqual(composed, decomposed) // Swift String equality
        XCTAssertFalse(AuthorizationClock.shared(scope: composed) === AuthorizationClock.shared(scope: decomposed))
    }

    func testUnavailableOrRegressingMonotonicSourceFallsBackToTheWallClock() async {
        let missing = ManualClockSource(wall: base, monotonic: nil)
        let missingClock = missing.makeTrustedClock()
        missing.wall = base - 3_600
        XCTAssertEqual(missingClock.now().timeIntervalSince1970, base - 3_600)

        let regressing = ManualClockSource(wall: base, monotonic: 10_000_000_000)
        let regressingClock = regressing.makeTrustedClock()
        regressing.monotonic = 1
        regressing.wall = base - 3_600
        XCTAssertEqual(regressingClock.now().timeIntervalSince1970, base - 3_600)
    }

    func testSystemMonotonicSourceIsAvailableAndNonDecreasing() async throws {
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

    func testOnlineAnchorAndResetSemantics() async throws {
        let sdk = LicenseSeat(
            config: LicenseSeatConfig(
                productSlug: "clock-app",
                storagePrefix: "authorization_clock_test_\(UUID().uuidString)_"
            )
        )
        defer { sdk.reset() }
        let source = ManualClockSource()
        sdk.authorizationClock = source.makeTrustedClock()

        source.elapse(3_600)
        source.wall -= 3_600
        XCTAssertEqual(sdk.authorizationClock.wallClockLag(), 3_600)

        // reset()/clear() preserve the floor exactly as they preserve the
        // persisted watermark.
        sdk.reset()
        XCTAssertEqual(sdk.authorizationClock.wallClockLag(), 3_600)

        // An online success without a server Date anchors the watermark (on
        // the wall clock, per the cross-SDK contract) but keeps the trusted
        // floor: the local clock is never promoted to a trusted epoch.
        XCTAssertTrue(sdk.anchorAuthoritativeTime(Date(timeIntervalSince1970: source.wall)))
        XCTAssertEqual(sdk.authorizationClock.wallClockLag(), 3_600)
        XCTAssertEqual(
            try XCTUnwrap(sdk.lastSeenTimestamp()).timeIntervalSince1970,
            source.wall,
            accuracy: 0.001
        )
    }

    func testOnlyTheSampledWallReadingIsPersisted() async throws {
        // R2-2: the wall clock moving between evaluation and persistence must
        // not let the synthetic floor (or a later reading) into the watermark.
        let sdk = LicenseSeat(
            config: LicenseSeatConfig(
                productSlug: "clock-app",
                storagePrefix: "authorization_clock_test_\(UUID().uuidString)_"
            )
        )
        defer { sdk.reset() }
        let source = ManualClockSource(wall: base)
        sdk.authorizationClock = source.makeClock()
        sdk.authorizationClock.anchor(trustedTime: Date(timeIntervalSince1970: base + 3_600))

        let instant = sdk.authorizationSnapshot()
        XCTAssertEqual(instant.effective.timeIntervalSince1970, base + 3_300)
        source.wall = base + 7_200
        try sdk.persistOfflineClockState(instant, clockSkewSeconds: 300)

        XCTAssertEqual(try XCTUnwrap(sdk.lastSeenTimestamp()).timeIntervalSince1970, base)
    }}
