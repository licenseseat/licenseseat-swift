//
//  AuthorizationClock.swift
//  LicenseSeatSDK
//
//  Wall-clock time paired with a monotonic process clock, so authorization
//  time cannot be moved backwards while the process is running.
//

import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// The instant every local authorization decision is evaluated at.
///
/// The persisted clock-rollback watermark only remembers the last moment the
/// SDK *recorded*. Between two recordings the wall clock can be wound back
/// without falling below that watermark: verify a signed grant at 09:00, keep
/// the app running until 11:00, set the clock to 09:30, and a grant that
/// expired at 10:00 would look valid again. A monotonic clock cannot be set
/// by the user, so pairing the wall-clock anchor with it gives a lower bound
/// on the real current time for as long as the process lives:
///
///     authorizationTime = max(wallNow, anchorWall + monotonicElapsed)
///
/// Lockout safety is the other half of the contract, and it is why this is a
/// floor and nothing more:
///
/// - The result is never *earlier* than the wall clock, so nothing that passes
///   on wall-clock time today can start failing because of this type. The
///   persisted watermark check (`now + skew < watermark`) only gets more
///   lenient, never stricter.
/// - The monotonic source keeps counting through system sleep (Darwin
///   `CLOCK_MONOTONIC`, Linux `CLOCK_BOOTTIME`), so sleeping never makes the
///   floor lag; and because it is a lower bound, any lag would only weaken
///   detection, never lock anyone out.
/// - Time zones and daylight saving time do not exist at this layer: both the
///   wall reading and the floor are seconds since 1970 UTC.
/// - The floor does **not** remember the largest wall reading it has seen.
///   A clock that is briefly wrong in the future and then corrected by NTP
///   (forward-then-back) settles back to real time instead of staying in the
///   future for the rest of the process. Forward-then-backward *tampering* is
///   still caught by the persisted watermark, which offline verification
///   ratchets with whatever time it accepted.
/// - Authoritative online success re-anchors it (see ``anchor()``), mirroring
///   the persisted watermark's anchor-on-online-success contract, so a wall
///   clock that was wrong when the SDK started is corrected on the next
///   successful validation, activation, or heartbeat.
/// - It is process-local and never persisted: a reboot or relaunch starts a
///   fresh anchor, and `reset()`/`clear()` leave it alone exactly as they
///   leave the persisted watermark alone.
@MainActor
final class AuthorizationClock {
    typealias WallClock = @MainActor () -> TimeInterval
    typealias MonotonicClock = @MainActor () -> UInt64?

    private let wallClock: WallClock
    private let monotonicClock: MonotonicClock
    private var anchorWall: TimeInterval
    private var anchorMonotonic: UInt64?

    /// - Parameters:
    ///   - wallClock: Seconds since 1970 UTC. Defaults to the system clock.
    ///   - monotonicClock: Nanoseconds from an arbitrary origin that only moves
    ///     forward and keeps counting through sleep, or `nil` when unavailable.
    init(
        wallClock: @escaping WallClock = { Date().timeIntervalSince1970 },
        monotonicClock: @escaping MonotonicClock = AuthorizationClock.systemMonotonicNanoseconds
    ) {
        self.wallClock = wallClock
        self.monotonicClock = monotonicClock
        self.anchorWall = wallClock()
        self.anchorMonotonic = monotonicClock()
    }

    /// Re-baseline on the current wall clock. Called only after authoritative
    /// online acceptance, together with the persisted watermark anchor; it may
    /// lower the floor (for example after NTP corrected a fast clock).
    func anchor() {
        anchorWall = wallClock()
        anchorMonotonic = monotonicClock()
    }

    /// The current authorization instant: the wall clock, raised to the
    /// monotonic floor when the wall clock has been moved behind it.
    func now() -> Date {
        let wall = wallClock()
        guard let floor = monotonicFloor(), floor > wall else {
            return Date(timeIntervalSince1970: wall)
        }
        return Date(timeIntervalSince1970: floor)
    }

    /// How far the wall clock currently trails the monotonic floor, in seconds
    /// (zero when it does not). Diagnostic only.
    func wallClockLag() -> TimeInterval {
        guard let floor = monotonicFloor() else { return 0 }
        return max(0, floor - wallClock())
    }

    private func monotonicFloor() -> TimeInterval? {
        guard anchorWall.isFinite, anchorWall > 0,
              let anchorMonotonic,
              let current = monotonicClock(),
              current >= anchorMonotonic else {
            return nil
        }
        let floor = anchorWall + Double(current - anchorMonotonic) / 1_000_000_000
        return floor.isFinite ? floor : nil
    }

    /// A monotonic clock that keeps counting while the system sleeps.
    nonisolated static func systemMonotonicNanoseconds() -> UInt64? {
        #if canImport(Darwin)
        // Darwin's CLOCK_MONOTONIC is mach_continuous_time based: it is
        // rate-corrected, cannot be set, and continues through sleep.
        let value = clock_gettime_nsec_np(CLOCK_MONOTONIC)
        return value == 0 ? nil : value
        #elseif canImport(Glibc) || canImport(Musl)
        // CLOCK_BOOTTIME is CLOCK_MONOTONIC plus time spent suspended.
        var spec = timespec()
        guard clock_gettime(CLOCK_BOOTTIME, &spec) == 0,
              spec.tv_sec >= 0, spec.tv_nsec >= 0 else {
            return nil
        }
        let (seconds, overflow) = UInt64(spec.tv_sec)
            .multipliedReportingOverflow(by: 1_000_000_000)
        guard !overflow else { return nil }
        return seconds &+ UInt64(spec.tv_nsec)
        #else
        return nil
        #endif
    }
}
