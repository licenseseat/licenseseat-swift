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
/// The API returns errors in the format: `{"error": {"code": "...", "message": "..."}}`
///
/// Use `code` for programmatic error handling:
/// - `license_not_found`: License key doesn't exist
/// - `product_not_found`: Product doesn't exist
/// - `expired`: License has expired
/// - `revoked`: License has been revoked
/// - `suspended`: License is suspended
/// - `seat_limit_exceeded`: All seats are in use
/// - `device_not_activated`: Device is not activated for this license
/// - `parameter_missing`: Required parameter is missing
public struct APIError: LocalizedError, Equatable, Sendable {
    /// Machine-readable error code for programmatic handling
    public let code: String?

    /// Human-readable error message
    public let message: String

    /// HTTP status code
    public let status: Int

    /// Additional error details (if available)
    public let details: [String: Any]?

    public var errorDescription: String? {
        return message
    }

    /// Create an API error from the new nested format: `{"error": {"code": "...", "message": "..."}}`
    public init(from responseData: [String: Any], status: Int) {
        self.status = status
        if let errorObj = responseData["error"] as? [String: Any] {
            self.code = errorObj["code"] as? String
            self.message = errorObj["message"] as? String ?? "Unknown error"
            self.details = errorObj["details"] as? [String: Any]
        } else {
            // Fallback for non-standard error responses
            self.code = nil
            self.message = responseData["message"] as? String ?? "Request failed"
            self.details = nil
        }
    }

    /// Create an API error with explicit values
    public init(code: String? = nil, message: String, status: Int, details: [String: Any]? = nil) {
        self.code = code
        self.message = message
        self.status = status
        self.details = details
    }

    // MARK: - Equatable (ignoring details)

    public static func == (lhs: APIError, rhs: APIError) -> Bool {
        return lhs.code == rhs.code &&
               lhs.message == rhs.message &&
               lhs.status == rhs.status
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
        guard let code = code else { return false }
        return ["revoked", "expired", "suspended", "license_revoked", "license_expired", "license_suspended"].contains(code)
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