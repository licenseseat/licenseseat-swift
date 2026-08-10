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

        // The current Rails API emits canonical padded Base64 for public keys
        // and signatures. Older/native producers may emit canonical unpadded
        // Base64URL. Accept those two explicit RFC 4648 forms, but reject
        // whitespace, mixed alphabets, and malformed padding.
        let urlSafeAlphabet = CharacterSet(
            charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"
        )
        if !string.isEmpty,
           string.unicodeScalars.allSatisfy(urlSafeAlphabet.contains),
           string.utf8.count % 4 != 1 {
            var base64 = string
                .replacingOccurrences(of: "-", with: "+")
                .replacingOccurrences(of: "_", with: "/")

            let remainder = base64.utf8.count % 4
            if remainder > 0 {
                base64.append(String(repeating: "=", count: 4 - remainder))
            }

            guard let data = Data(base64Encoded: base64),
                  encode(data) == string else {
                throw Base64URLError.invalidInput
            }
            return data
        }

        let standardPattern = #"\A[A-Za-z0-9+/]+={0,2}\z"#
        guard string.utf8.count.isMultiple(of: 4),
              string.range(of: standardPattern, options: .regularExpression) != nil,
              let data = Data(base64Encoded: string),
              data.base64EncodedString() == string else {
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
