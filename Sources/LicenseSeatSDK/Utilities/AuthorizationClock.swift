//
//  AuthorizationClock.swift
//  LicenseSeatSDK
//
//  Wall-clock time paired with a monotonic process clock, so authorization
//  time cannot be wound back while the process is running.
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
/// by the user, so an anchor plus monotonic elapsed time is a lower bound on
/// the real current time for as long as the process lives:
///
///     floor             = anchor + monotonicElapsed
///     authorizationTime = max(wallNow, floor − tolerance)
///
/// where `tolerance` is the configured `maxClockSkewMs`.
///
/// **Anchor.** The process starts anchored on its own wall clock. Every
/// authoritative online success re-anchors it — on the server's HTTP `Date`
/// when the response carried one (a trusted lower bound on real time), else on
/// the wall clock — mirroring the persisted watermark's anchor-on-online-
/// success contract. The anchor is shared by every `LicenseSeat` instance with
/// the same storage prefix in this process, so replacing the instance (for
/// example `configure(force: true)`) cannot be used to discard it.
///
/// **Lockout safety** is the other half of the contract:
///
/// - The result is never earlier than the wall clock, so a check that passes
///   on wall-clock time cannot start failing because of a *slow* wall clock,
///   and the watermark comparison (`authorizationTime + skew < watermark`)
///   can only become more lenient.
/// - A wall clock that was fast when the anchor was taken and is then
///   corrected by NTP moves the floor ahead of real time by the error. The
///   `tolerance` absorbs errors up to `maxClockSkewMs`; a server-time anchor
///   (the next online success) removes the error entirely.
/// - Only wall-clock readings are ever persisted; the floor is process-local
///   and never written to the watermark, so a relaunch or reboot starts fresh
///   and a corrected clock is never compared against a synthetic future.
/// - The monotonic source keeps counting through system sleep (Darwin
///   `CLOCK_MONOTONIC`, Linux `CLOCK_BOOTTIME`). Were it ever to lag, the floor
///   would only fall behind real time — weaker detection, never a lockout.
/// - Time zones and daylight saving time do not exist at this layer: every
///   value is seconds since 1970 UTC.
/// - Forward wall-clock excursions are not remembered: a briefly wrong future
///   clock settles back to real time once corrected. Forward-then-backward
///   *tampering* during which an offline verification succeeded is still
///   caught by the persisted watermark.
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

    // MARK: - Process-wide scope

    private static var clocksByScope: [String: AuthorizationClock] = [:]

    /// The clock shared by every SDK instance using `scope` (the storage
    /// prefix) in this process.
    static func shared(scope: String) -> AuthorizationClock {
        if let clock = clocksByScope[scope] { return clock }
        let clock = AuthorizationClock()
        clocksByScope[scope] = clock
        return clock
    }

    // MARK: - Reading

    /// The current wall-clock reading, the only time value ever persisted.
    func wallTime() -> Date {
        Date(timeIntervalSince1970: wallClock())
    }

    /// The current authorization instant: the wall clock, raised to the
    /// monotonic floor (less `tolerance` seconds) when the wall clock has been
    /// moved behind it.
    func now(tolerance: TimeInterval = 0) -> Date {
        let wall = wallClock()
        let slack = tolerance.isFinite ? max(0, tolerance) : 0
        guard let floor = monotonicFloor(), floor - slack > wall else {
            return Date(timeIntervalSince1970: wall)
        }
        return Date(timeIntervalSince1970: floor - slack)
    }

    /// How far the wall clock currently trails the monotonic floor, in seconds
    /// (zero when it does not). Diagnostic only.
    func wallClockLag() -> TimeInterval {
        guard let floor = monotonicFloor() else { return 0 }
        return max(0, floor - wallClock())
    }

    // MARK: - Anchoring

    /// Re-baseline after authoritative online acceptance. `trustedTime` is the
    /// server's `Date`; without one the current wall clock is used. Either may
    /// lower the floor (for example after NTP corrected a fast clock).
    func anchor(trustedTime: Date? = nil) {
        let trusted = trustedTime?.timeIntervalSince1970
        if let trusted, trusted.isFinite, trusted > 0 {
            anchorWall = trusted
        } else {
            anchorWall = wallClock()
        }
        anchorMonotonic = monotonicClock()
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
