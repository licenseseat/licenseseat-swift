//
//  APIError.swift
//  LicenseSeatSDK
//
//  Created by LicenseSeat on 2025.
//  Copyright © 2025 LicenseSeat. All rights reserved.
//

import Foundation

/// API error with status code and response data
///
/// This error type represents errors returned by the LicenseSeat API.
/// Use `reasonCode` for programmatic error handling.
public struct APIError: LocalizedError, Equatable {
    /// Human-readable error message
    public let message: String

    /// HTTP status code
    public let status: Int

    /// Machine-readable error code for programmatic handling
    ///
    /// Common values:
    /// - `license_not_found`: License key doesn't exist
    /// - `product_mismatch`: License product doesn't match requested product
    /// - `expired`: License has expired
    /// - `revoked`: License has been revoked
    /// - `suspended`: License is suspended
    /// - `not_active`: License is pending, canceled, or not yet started
    /// - `seat_limit_exceeded`: All seats are in use
    /// - `device_not_activated`: Device is not activated for this license
    /// - `parameter_missing`: Required parameter is missing
    public let reasonCode: String?

    /// Response data (if available)
    public let data: [String: Any]?

    public var errorDescription: String? {
        return message
    }

    public init(message: String, status: Int, data: [String: Any]?) {
        self.message = message
        self.status = status
        self.data = data
        self.reasonCode = data?["reason_code"] as? String
    }

    /// Create an API error with explicit reason code
    public init(message: String, status: Int, reasonCode: String? = nil) {
        self.message = message
        self.status = status
        self.reasonCode = reasonCode
        self.data = nil
    }

    // MARK: - Equatable (ignoring data)

    public static func == (lhs: APIError, rhs: APIError) -> Bool {
        return lhs.message == rhs.message &&
               lhs.status == rhs.status &&
               lhs.reasonCode == rhs.reasonCode
    }

    // MARK: - Error Classification

    /// Whether this error indicates a network/transport failure
    public var isNetworkError: Bool {
        return status == 0 || status == 408
    }

    /// Whether this error indicates a server-side issue (5xx)
    public var isServerError: Bool {
        return status >= 500 && status < 600
    }

    /// Whether this error indicates a client error (4xx)
    public var isClientError: Bool {
        return status >= 400 && status < 500
    }

    /// Whether this error is due to authentication failure
    public var isAuthError: Bool {
        return status == 401 || status == 403
    }

    /// Whether this error indicates the license has a terminal state
    /// (revoked, expired, suspended) that won't change without intervention
    public var isLicenseTerminalError: Bool {
        guard let code = reasonCode else { return false }
        return ["revoked", "expired", "suspended"].contains(code)
    }

    /// Whether this error is retryable
    public var isRetryable: Bool {
        // Server errors (except 501 Not Implemented)
        if status >= 502 && status < 600 { return true }
        // Network/transport errors
        if [0, 408, 429].contains(status) { return true }
        return false
    }
} 