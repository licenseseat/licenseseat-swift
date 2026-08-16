//
//  LicenseSeatConfig.swift
//  LicenseSeatSDK
//
//  Created by LicenseSeat on 2025.
//  Copyright © 2025 LicenseSeat. All rights reserved.
//

import Foundation

/// Configuration options for the LicenseSeat SDK
///
/// Customize SDK behavior by providing a configuration during initialization.
/// All properties have sensible defaults for typical use cases.
///
/// ## Example
///
/// ```swift
/// let config = LicenseSeatConfig(
///     apiKey: "your-api-key",
///     productSlug: "my-app",
///     autoValidateInterval: 3600,     // Validate every hour
///     maxOfflineDays: 7               // Cap offline grants at 7 days
/// )
/// ```
public struct LicenseSeatConfig {
    // MARK: - Constants

    /// Upper bound for SDK-owned repeating schedules. Longer cadences should
    /// be owned explicitly by the host application.
    internal static let maximumScheduledInterval: TimeInterval = 366 * 86_400

    /// Request timeout applied when the host does not configure one.
    internal static let defaultRequestTimeout: TimeInterval = 30

    /// Upper bound for a single request timeout, matching the Rust SDK's
    /// configuration limit so both SDKs reject the same values.
    internal static let maximumRequestTimeout: TimeInterval = 300

    /// The current SDK version. Single source of truth for version information.
    public static let sdkVersion = "0.4.2"

    /// The production API base URL (v1). Single source of truth for the default endpoint.
    public static let productionAPIBaseURL = "https://licenseseat.com/api/v1"

    /// Base URL for the LicenseSeat API
    public var apiBaseUrl: String

    /// API key for authentication
    public var apiKey: String?

    /// Product slug (required for all license operations)
    public var productSlug: String?

    /// Prefix for storage keys
    public var storagePrefix: String

    /// Custom device identifier (optional)
    public var deviceIdentifier: String?

    /// Interval for automatic online validation (in seconds).
    /// Set to 0 or negative to disable both launch-time and periodic online
    /// validation. Local verification of a cached signed offline grant is
    /// unaffected, so hosts can own their validation cadence without weakening
    /// offline enforcement.
    public var autoValidateInterval: TimeInterval

    /// A single policy predicate shared by launch-time and periodic scheduling.
    /// The upper bound prevents conversion overflow when the interval is
    /// converted to nanoseconds for `Task.sleep`.
    internal var automaticValidationEnabled: Bool {
        autoValidateInterval.isFinite &&
            autoValidateInterval > 0 &&
            autoValidateInterval <= Self.maximumScheduledInterval
    }

    /// Interval for standalone heartbeat pings (in seconds).
    /// Independent from auto-validation; provides more frequent liveness updates.
    /// Set to 0 or negative to disable. Defaults to 300 (5 minutes).
    public var heartbeatInterval: TimeInterval

    /// Interval for network recheck when offline (in seconds)
    public var networkRecheckInterval: TimeInterval

    /// Timeout for a single API request (in seconds), applied to SDK-owned
    /// sessions. The resource timeout is twice this value. Defaults to 30.
    /// Sessions injected through `urlSession:` keep their own transport policy.
    public var requestTimeout: TimeInterval

    /// The timeout actually applied to an SDK-owned session. Non-finite,
    /// zero, negative, and above-``maximumRequestTimeout`` values fall back to
    /// the default so a misconfigured host cannot create a session that never
    /// times out or fails instantly.
    internal var resolvedRequestTimeout: TimeInterval {
        guard requestTimeout.isFinite,
              requestTimeout > 0,
              requestTimeout <= Self.maximumRequestTimeout else {
            return Self.defaultRequestTimeout
        }
        return requestTimeout
    }

    /// Maximum number of retry attempts for API calls
    public var maxRetries: Int

    /// Base delay for retry backoff (in seconds)
    public var retryDelay: TimeInterval

    /// Whether to enable debug logging
    public var debug: Bool

    /// Whether to include device telemetry (OS, platform, app version, etc.) with supported
    /// licensing POST requests (activation, validation, heartbeat, deactivation, and offline grants).
    ///
    /// Telemetry helps power per-product analytics in the LicenseSeat dashboard (DAU/MAU,
    /// version adoption, platform distribution). Device and application attributes can qualify
    /// as linked personal data under platform policy or privacy law; see <doc:Privacy>.
    ///
    /// Set to `false` to omit the optional `telemetry` object. Licensing identifiers, API
    /// interaction, and the server-visible source IP remain necessary for the service.
    /// Defaults to `true`; disabling this option alone does not establish legal compliance.
    public var telemetryEnabled: Bool

    /// Application version reported in telemetry. When `nil` the SDK reads
    /// `CFBundleShortVersionString` from the main bundle, which is unavailable
    /// for command-line tools and SPM-embedded hosts. An explicit value that is
    /// empty, longer than 255 bytes, or contains control characters is omitted
    /// from telemetry rather than replaced by the bundle value.
    public var appVersion: String?

    /// Application build reported in telemetry. When `nil` the SDK reads
    /// `CFBundleVersion` from the main bundle. The same bounds as
    /// ``appVersion`` apply.
    public var appBuild: String?

    /// Interval for refreshing offline token (in seconds)
    public var offlineTokenRefreshInterval: TimeInterval

    /// Determines how the SDK should behave when the network is unavailable or the
    /// backend returns an *unexpected* (≥500) server error during validation cycles.
    ///
    /// - `networkOnly`: The SDK falls back to the cached offline token **only** when
    ///   the error is clearly network-related (e.g. the device is offline, request
    ///   timeout, or the server responded with a 5xx status). Business-logic errors
    ///   coming from the backend (4xx) will **not** trigger an offline fallback.
    /// - `always`: Unconditionally attempts an offline fallback for *any* failure.
    public enum OfflineFallbackMode: String, Codable, Sendable {
        case networkOnly = "network_only"
        case always = "always"
    }

    /// Strategy for offline fallback during validation.
    public var offlineFallbackMode: OfflineFallbackMode

    /// Whether a cached signed grant may authorize the application while the
    /// backend is unreachable. Enabled by default, matching the Rust SDK.
    ///
    /// Set to `false` to require an authoritative online decision: cached
    /// grants cannot authorize features, launch-time offline verification is
    /// skipped, and background offline-token refresh never runs.
    public var offlineFallbackEnabled: Bool

    /// Maximum *additional* host-side age of a signed offline token in days.
    ///
    /// Zero — the default — applies no host-side age cap; the signed token's
    /// own `exp`, the license expiry claim, and the clock-rollback watermark
    /// remain the governing deadlines. Values are limited to 0...36,600
    /// (100 leap years); negative or larger values fail closed.
    public var maxOfflineDays: Int

    /// Whether this configuration permits a cached signed token to grant
    /// authority. One predicate is shared by startup, fallback, refresh, and
    /// explicit verification so an out-of-range policy cannot fail closed in
    /// one path and run unbounded in another.
    internal var offlineAuthorityEnabled: Bool {
        offlineFallbackEnabled && (0...36_600).contains(maxOfflineDays)
    }

    /// Maximum allowed clock skew (in milliseconds)
    public var maxClockSkewMs: TimeInterval

    /// Default configuration
    public static var `default`: LicenseSeatConfig {
        return LicenseSeatConfig()
    }

    /// Initialize with custom values
    public init(
        apiBaseUrl: String = LicenseSeatConfig.productionAPIBaseURL,
        apiKey: String? = nil,
        productSlug: String? = nil,
        storagePrefix: String = "licenseseat_",
        deviceIdentifier: String? = nil,
        autoValidateInterval: TimeInterval = 3600,
        heartbeatInterval: TimeInterval = 300,
        networkRecheckInterval: TimeInterval = 30,
        requestTimeout: TimeInterval = 30,
        maxRetries: Int = 3,
        retryDelay: TimeInterval = 1,
        debug: Bool = false,
        telemetryEnabled: Bool = true,
        appVersion: String? = nil,
        appBuild: String? = nil,
        offlineTokenRefreshInterval: TimeInterval = 259200,
        offlineFallbackMode: OfflineFallbackMode = .networkOnly,
        offlineFallbackEnabled: Bool = true,
        maxOfflineDays: Int = 0,
        maxClockSkewMs: TimeInterval = 300000
    ) {
        self.apiBaseUrl = apiBaseUrl
        self.apiKey = apiKey
        self.productSlug = productSlug
        self.storagePrefix = storagePrefix
        self.deviceIdentifier = deviceIdentifier
        self.autoValidateInterval = autoValidateInterval
        self.heartbeatInterval = heartbeatInterval
        self.networkRecheckInterval = networkRecheckInterval
        self.requestTimeout = requestTimeout
        self.maxRetries = maxRetries
        self.retryDelay = retryDelay
        self.debug = debug
        self.telemetryEnabled = telemetryEnabled
        self.appVersion = appVersion
        self.appBuild = appBuild
        self.offlineTokenRefreshInterval = offlineTokenRefreshInterval
        self.offlineFallbackMode = offlineFallbackMode
        self.offlineFallbackEnabled = offlineFallbackEnabled
        self.maxOfflineDays = maxOfflineDays
        self.maxClockSkewMs = maxClockSkewMs
    }
}
