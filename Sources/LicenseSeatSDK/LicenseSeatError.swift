//
//  LicenseSeatError.swift
//  LicenseSeatSDK
//
//  Created by LicenseSeat on 2025.
//  Copyright © 2025 LicenseSeat. All rights reserved.
//

import Foundation

/// Errors that can occur during SDK operations
public enum LicenseSeatError: LocalizedError {
    /// No active license found in cache
    case noActiveLicense
    
    /// API key is required but not configured
    case apiKeyRequired
    
    /// Offline license data is malformed or missing required fields
    case invalidOfflineLicense
    
    /// Public key ID is empty or invalid
    case invalidKeyId
    
    /// Public key format is invalid
    case invalidPublicKey
    
    /// Platform doesn't support required cryptographic operations
    case cryptoUnavailable
    
    /// Network operation failed
    case networkError
    
    /// Device identifier generation failed
    case deviceIdentifierError
    
    /// Cache operation failed
    case cacheError
    
    /// License validation failed
    case validationFailed(reason: String)
    
    /// Activation failed
    case activationFailed(reason: String)
    
    public var errorDescription: String? {
        switch self {
        case .noActiveLicense:
            return "No active license found"
        case .apiKeyRequired:
            return "API key is required for this operation"
        case .invalidKeyId:
            return "Invalid key ID"
        case .invalidPublicKey:
            return "Invalid public key"
        case .invalidOfflineLicense:
            return "Invalid offline license structure"
        case .cryptoUnavailable:
            return "Cryptographic functionality unavailable on this platform"
        case .networkError:
            return "Network operation failed"
        case .deviceIdentifierError:
            return "Device identifier generation failed"
        case .cacheError:
            return "Cache operation failed"
        case .validationFailed(let reason):
            return "License validation failed: \(reason)"
        case .activationFailed(let reason):
            return "License activation failed: \(reason)"
        }
    }
} 