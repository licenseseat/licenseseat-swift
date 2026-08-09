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
        guard !string.isEmpty,
              string.utf8.count <= 1_500_000,
              string.unicodeScalars.allSatisfy({ $0.isASCII }) else {
            throw Base64URLError.invalidInput
        }

        let usesURLAlphabet = string.contains("-") || string.contains("_")
        let usesStandardAlphabet = string.contains("+") || string.contains("/")
        guard !(usesURLAlphabet && usesStandardAlphabet) else {
            throw Base64URLError.invalidInput
        }

        let unpadded = string.trimmingCharacters(in: CharacterSet(charactersIn: "="))
        let paddingCount = string.count - unpadded.count
        guard paddingCount <= 2,
              !unpadded.contains("="),
              unpadded.count % 4 != 1 else {
            throw Base64URLError.invalidInput
        }

        let allowed = usesURLAlphabet
            ? "^[A-Za-z0-9_-]+={0,2}$"
            : "^[A-Za-z0-9+/]+={0,2}$"
        guard string.range(of: allowed, options: .regularExpression) != nil else {
            throw Base64URLError.invalidInput
        }

        // Convert from Base64URL to standard Base64 for Foundation.
        var base64 = unpadded
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
        
        let canonicalStandard = data.base64EncodedString()
        if usesURLAlphabet {
            let canonicalURL = encode(data)
            let paddedURL = canonicalStandard
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
            guard string == canonicalURL || string == paddedURL else {
                throw Base64URLError.invalidInput
            }
        } else {
            guard string == canonicalStandard || string == canonicalStandard.trimmingCharacters(in: CharacterSet(charactersIn: "=")) else {
                throw Base64URLError.invalidInput
            }
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
