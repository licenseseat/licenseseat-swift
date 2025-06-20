//
//  Base64URL.swift
//  LicenseSeatSDK
//
//  Created by LicenseSeat on 2025.
//  Copyright © 2025 LicenseSeat. All rights reserved.
//

import Foundation

/// Base64URL encoding/decoding utilities
enum Base64URL {
    
    /// Encode data to Base64URL string
    static func encode(_ data: Data) -> String {
        let base64 = data.base64EncodedString()
        
        // Convert to Base64URL
        return base64
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
    
    /// Decode Base64URL string to data
    static func decode(_ string: String) throws -> Data {
        // Convert from Base64URL to Base64
        var base64 = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        
        // Add padding if needed
        let remainder = base64.count % 4
        if remainder > 0 {
            base64.append(String(repeating: "=", count: 4 - remainder))
        }
        
        guard let data = Data(base64Encoded: base64) else {
            throw Base64URLError.invalidInput
        }
        
        return data
    }
}

/// Base64URL errors
enum Base64URLError: LocalizedError {
    case invalidInput
    
    var errorDescription: String? {
        switch self {
        case .invalidInput:
            return "Invalid Base64URL input"
        }
    }
} 