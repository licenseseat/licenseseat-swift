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
///     maxOfflineDays: 7               // 7-day grace period
/// )
/// ```
public struct LicenseSeatConfig {
    // MARK: - Constants

    /// The current SDK version. Single source of truth for version information.
    public static let sdkVersion = "0.3.0"

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

    /// Interval for automatic validation (in seconds)
    public var autoValidateInterval: TimeInterval

    /// Interval for network recheck when offline (in seconds)
    public var networkRecheckInterval: TimeInterval

    /// Maximum number of retry attempts for API calls
    public var maxRetries: Int

    /// Base delay for retry backoff (in seconds)
    public var retryDelay: TimeInterval

    /// Whether to enable debug logging
    public var debug: Bool

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

    /// Maximum number of days to allow offline usage (0 = disabled)
    public var maxOfflineDays: Int

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
        networkRecheckInterval: TimeInterval = 30,
        maxRetries: Int = 3,
        retryDelay: TimeInterval = 1,
        debug: Bool = false,
        offlineTokenRefreshInterval: TimeInterval = 259200,
        offlineFallbackMode: OfflineFallbackMode = .networkOnly,
        maxOfflineDays: Int = 0,
        maxClockSkewMs: TimeInterval = 300000
    ) {
        self.apiBaseUrl = apiBaseUrl
        self.apiKey = apiKey
        self.productSlug = productSlug
        self.storagePrefix = storagePrefix
        self.deviceIdentifier = deviceIdentifier
        self.autoValidateInterval = autoValidateInterval
        self.networkRecheckInterval = networkRecheckInterval
        self.maxRetries = maxRetries
        self.retryDelay = retryDelay
        self.debug = debug
        self.offlineTokenRefreshInterval = offlineTokenRefreshInterval
        self.offlineFallbackMode = offlineFallbackMode
        self.maxOfflineDays = maxOfflineDays
        self.maxClockSkewMs = maxClockSkewMs
    }
} 