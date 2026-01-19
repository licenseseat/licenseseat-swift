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
///     autoValidateInterval: 3600,     // Validate every hour
///     strictOfflineFallback: true,   // Enable offline mode (network-only fallback)
///     maxOfflineDays: 7              // 7-day grace period
/// )
/// ```
public struct LicenseSeatConfig {
    // MARK: - Constants

    /// The production API base URL. Single source of truth for the default endpoint.
    public static let productionAPIBaseURL = "https://licenseseat.com/api"
    /// Base URL for the LicenseSeat API
    public var apiBaseUrl: String
    
    /// API key for authentication
    public var apiKey: String?
    
    /// Prefix for storage keys
    public var storagePrefix: String
    
    /// Custom device identifier (optional)
    public var deviceIdentifier: String?
    
    /// Interval for automatic validation (in seconds)
    public var autoValidateInterval: TimeInterval
    
    /// Interval for network recheck when offline (in seconds)
    public var networkRecheckInterval: TimeInterval
    
    /// Maximum number of retry attempts for API calls
    public var maxRetries: Int
    
    /// Base delay for retry backoff (in milliseconds)
    public var retryDelay: TimeInterval
    
    /// Whether to enable debug logging
    public var debug: Bool
    
    /// Interval for refreshing offline license (in seconds)
    public var offlineLicenseRefreshInterval: TimeInterval
    
    /// Determines how the SDK should behave when the network is unavailable or the
    /// backend returns an *unexpected* (≥500) server error during validation cycles.
    ///
    /// - `networkOnly`: (New default)  The SDK falls back to the cached offline
    ///   license **only** when the error is clearly network-related (e.g. the
    ///   device is offline, request timeout, or the server responded with a 5xx
    ///   status).  Business-logic errors coming from the backend (4xx) will **not**
    ///   trigger an offline fallback – the cache is purged instead so the host app
    ///   can react to the invalid status immediately.
    /// - `always`: Legacy, permissive behaviour that unconditionally attempts an
    ///   offline fallback for *any* failure.  Applications that relied on the old
    ///   semantics can opt-in to this mode for a smooth migration.
    public enum OfflineFallbackMode: String, Codable {
        case networkOnly = "network_only"
        case always = "always"
    }
    
    /// Strategy for offline fallback during validation.
    public var offlineFallbackMode: OfflineFallbackMode
    
    /// Maximum number of days to allow offline usage (0 = disabled)
    public var maxOfflineDays: Int
    
    /// Maximum allowed clock skew (in milliseconds)
    public var maxClockSkewMs: TimeInterval
    
    /// Backwards-compatibility shim.  Accessing this property emits a deprecation
    /// warning while seamlessly mapping to the new `offlineFallbackMode`.
    @available(*, deprecated, renamed: "offlineFallbackMode")
    public var offlineFallbackEnabled: Bool {
        get { offlineFallbackMode == .always }
        set { offlineFallbackMode = newValue ? .always : .networkOnly }
    }
    
    /// Alias for the stricter behaviour flag preferred by some integrators.
    ///
    /// Setting this to `true` enables the *network-only* fallback; `false` brings
    /// back the legacy permissive mode (identical to `offlineFallbackMode == .always`).
    /// The name reflects its semantics so it is clear at call-site what it does.
    public var strictOfflineFallback: Bool {
        get { offlineFallbackMode == .networkOnly }
        set { offlineFallbackMode = newValue ? .networkOnly : .always }
    }
    
    /// Default configuration
    public static var `default`: LicenseSeatConfig {
        return LicenseSeatConfig(
            apiBaseUrl: productionAPIBaseURL,
            apiKey: nil,
            storagePrefix: "licenseseat_",
            deviceIdentifier: nil,
            autoValidateInterval: 3600, // 1 hour
            networkRecheckInterval: 30, // 30 seconds
            maxRetries: 3,
            retryDelay: 1, // 1 second
            debug: false,
            offlineLicenseRefreshInterval: 259200, // 72 hours
            offlineFallbackEnabled: false,
            maxOfflineDays: 0,
            maxClockSkewMs: 300000 // 5 minutes
        )
    }
    
    /// Initialize with custom values
    public init(
        apiBaseUrl: String = LicenseSeatConfig.productionAPIBaseURL,
        apiKey: String? = nil,
        storagePrefix: String = "licenseseat_",
        deviceIdentifier: String? = nil,
        autoValidateInterval: TimeInterval = 3600,
        networkRecheckInterval: TimeInterval = 30,
        maxRetries: Int = 3,
        retryDelay: TimeInterval = 1,
        debug: Bool = false,
        offlineLicenseRefreshInterval: TimeInterval = 259200,
        offlineFallbackEnabled: Bool = false,
        maxOfflineDays: Int = 0,
        maxClockSkewMs: TimeInterval = 300000
    ) {
        self.apiBaseUrl = apiBaseUrl
        self.apiKey = apiKey
        self.storagePrefix = storagePrefix
        self.deviceIdentifier = deviceIdentifier
        self.autoValidateInterval = autoValidateInterval
        self.networkRecheckInterval = networkRecheckInterval
        self.maxRetries = maxRetries
        self.retryDelay = retryDelay
        self.debug = debug
        self.offlineLicenseRefreshInterval = offlineLicenseRefreshInterval
        self.offlineFallbackMode = offlineFallbackEnabled ? .always : .networkOnly
        self.maxOfflineDays = maxOfflineDays
        self.maxClockSkewMs = maxClockSkewMs
    }
} 