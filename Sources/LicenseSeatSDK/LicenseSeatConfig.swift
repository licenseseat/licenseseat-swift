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
///     apiBaseUrl: "https://api.licenseseat.com",
///     apiKey: "your-api-key",
///     autoValidateInterval: 3600,     // Validate every hour
///     offlineFallbackEnabled: true,   // Enable offline mode
///     maxOfflineDays: 7              // 7-day grace period
/// )
/// ```
public struct LicenseSeatConfig {
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
    
    /// Whether offline fallback is enabled
    public var offlineFallbackEnabled: Bool
    
    /// Maximum number of days to allow offline usage (0 = disabled)
    public var maxOfflineDays: Int
    
    /// Maximum allowed clock skew (in milliseconds)
    public var maxClockSkewMs: TimeInterval
    
    /// Default configuration
    public static var `default`: LicenseSeatConfig {
        return LicenseSeatConfig(
            apiBaseUrl: "https://api.licenseseat.com",
            apiKey: nil,
            storagePrefix: "licenseseat_",
            deviceIdentifier: nil,
            autoValidateInterval: 3600, // 1 hour
            networkRecheckInterval: 30, // 30 seconds
            maxRetries: 3,
            retryDelay: 1, // 1 second
            debug: false,
            offlineLicenseRefreshInterval: 259200, // 72 hours
            offlineFallbackEnabled: true,
            maxOfflineDays: 0,
            maxClockSkewMs: 300000 // 5 minutes
        )
    }
    
    /// Initialize with custom values
    public init(
        apiBaseUrl: String = "https://api.licenseseat.com",
        apiKey: String? = nil,
        storagePrefix: String = "licenseseat_",
        deviceIdentifier: String? = nil,
        autoValidateInterval: TimeInterval = 3600,
        networkRecheckInterval: TimeInterval = 30,
        maxRetries: Int = 3,
        retryDelay: TimeInterval = 1,
        debug: Bool = false,
        offlineLicenseRefreshInterval: TimeInterval = 259200,
        offlineFallbackEnabled: Bool = true,
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
        self.offlineFallbackEnabled = offlineFallbackEnabled
        self.maxOfflineDays = maxOfflineDays
        self.maxClockSkewMs = maxClockSkewMs
    }
} 