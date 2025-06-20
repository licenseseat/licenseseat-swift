//
//  APIError.swift
//  LicenseSeatSDK
//
//  Created by LicenseSeat on 2025.
//  Copyright © 2025 LicenseSeat. All rights reserved.
//

import Foundation

/// API error with status code and response data
public struct APIError: LocalizedError {
    /// Error message
    public let message: String
    
    /// HTTP status code
    public let status: Int
    
    /// Response data (if available)
    public let data: Any?
    
    public var errorDescription: String? {
        return message
    }
    
    public init(message: String, status: Int, data: Any?) {
        self.message = message
        self.status = status
        self.data = data
    }
} 