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

/// One reading of the authorization clock: the wall clock as sampled, and the
/// authorization instant derived from it. Claims are evaluated at
/// `effective`; only `wall` is ever persisted.
struct AuthorizationInstant: Equatable {
    let wall: Date
    let effective: Date
}

/// The instant every local authorization decision is evaluated at.
///
/// The persisted clock-rollback watermark only remembers the last moment the
/// SDK *recorded*. Between two recordings the wall clock can be wound back
/// without falling below it. A monotonic clock cannot be set, so a **trusted**
/// time sample plus monotonic elapsed time is a lower bound on real time for
/// as long as the process lives:
///
///     floor             = trustedSample + monotonicElapsed
///     authorizationTime = max(wallNow, floor − tolerance)
///
/// where `tolerance` is the configured `maxClockSkewMs`.
///
/// **Only trusted samples create a floor.** A trusted sample is the licensing
/// server's HTTP `Date` on an authoritative online success (activation,
/// validation, heartbeat), accepted only if it is no more than
/// ``maximumTrustedLead`` ahead of the local wall clock (a proxy stamping
/// 2099 is ignored). The local wall clock is never a trusted sample: a fast
/// clock that NTP later corrects and a deliberate rollback produce identical
/// wall/monotonic observations, so flooring on the local clock either locks a
/// legitimate customer out early or reopens rollback. Until the first trusted
/// sample in this process, `authorizationTime == wall` and rollback detection
/// is the persisted watermark's alone (the pre-0.6 behaviour). A later online
/// success without a usable `Date` keeps the existing trusted baseline.
///
/// Lockout safety:
/// - Never earlier than the wall clock; the watermark comparison only becomes
///   more lenient.
/// - No floor from an untrusted local reading, so a clock that was wrong at
///   launch can never expire a grant early.
/// - Only wall-clock readings are persisted (``AuthorizationInstant/wall``,
///   sampled once with the effective time), never the floor.
/// - The monotonic source keeps counting through sleep; a lagging source only
///   weakens detection. UTC throughout, so time zones and DST never enter.
///
/// Known, bounded limits (documented, tested):
/// - Rollback by less than `tolerance` below the trusted floor is accepted
///   (the skew allowance applies to the floor too).
/// - A cold offline session with no trusted sample relies on the persisted
///   watermark only.
@MainActor
final class AuthorizationClock {
    typealias WallClock = @MainActor () -> TimeInterval
    typealias MonotonicClock = @MainActor () -> UInt64?

    /// How far ahead of the local wall clock a server time may be and still
    /// be trusted. A local clock slower than this gets no floor (the
    /// persisted watermark still applies); an implausible server/proxy date
    /// can never move authorization time more than this far ahead.
    static let maximumTrustedLead: TimeInterval = 24 * 3_600

    private let wallClock: WallClock
    private let monotonicClock: MonotonicClock
    private var trustedSample: TimeInterval?
    private var trustedMonotonic: UInt64?

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
    }

    // MARK: - Process-wide scope

    /// Keyed by the scope's exact UTF-8 bytes, matching how the storage
    /// namespace is derived (Swift `String` equality would merge canonically
    /// equivalent but byte-different prefixes that have separate caches).
    private static var clocksByScope: [[UInt8]: AuthorizationClock] = [:]

    /// The clock shared by every SDK instance using `scope` (the storage
    /// prefix) in this process.
    static func shared(scope: String) -> AuthorizationClock {
        let key = Array(scope.utf8)
        if let clock = clocksByScope[key] { return clock }
        let clock = AuthorizationClock()
        clocksByScope[key] = clock
        return clock
    }

    // MARK: - Reading

    /// The current wall-clock reading.
    func wallTime() -> Date {
        Date(timeIntervalSince1970: wallClock())
    }

    /// Whether a trusted sample has established a floor in this process.
    var hasTrustedBaseline: Bool { trustedSample != nil }

    /// One consistent reading: the wall clock sampled once, and the
    /// authorization instant derived from that same sample.
    func snapshot(tolerance: TimeInterval = 0) -> AuthorizationInstant {
        let wall = wallClock()
        let slack = tolerance.isFinite ? max(0, tolerance) : 0
        guard let floor = monotonicFloor(), floor - slack > wall else {
            let date = Date(timeIntervalSince1970: wall)
            return AuthorizationInstant(wall: date, effective: date)
        }
        return AuthorizationInstant(
            wall: Date(timeIntervalSince1970: wall),
            effective: Date(timeIntervalSince1970: floor - slack)
        )
    }

    /// The current authorization instant (see ``snapshot(tolerance:)``).
    func now(tolerance: TimeInterval = 0) -> Date {
        snapshot(tolerance: tolerance).effective
    }

    /// How far the wall clock currently trails the trusted floor, in seconds
    /// (zero when it does not or there is no trusted floor). Diagnostic only.
    func wallClockLag() -> TimeInterval {
        guard let floor = monotonicFloor() else { return 0 }
        return max(0, floor - wallClock())
    }

    // MARK: - Anchoring

    /// Record authoritative online acceptance. A plausible `trustedTime` (the
    /// server's `Date`) becomes the new trusted baseline, which may lower the
    /// floor. Without one, an existing trusted baseline is kept unchanged.
    func anchor(trustedTime: Date? = nil) {
        guard let trusted = trustedTime?.timeIntervalSince1970,
              trusted.isFinite, trusted > 0,
              trusted <= wallClock() + Self.maximumTrustedLead,
              let monotonic = monotonicClock() else {
            return
        }
        trustedSample = trusted
        trustedMonotonic = monotonic
    }

    private func monotonicFloor() -> TimeInterval? {
        guard let trustedSample, trustedSample.isFinite, trustedSample > 0,
              let trustedMonotonic,
              let current = monotonicClock(),
              current >= trustedMonotonic else {
            return nil
        }
        let floor = trustedSample + Double(current - trustedMonotonic) / 1_000_000_000
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
