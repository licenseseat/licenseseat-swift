//
//  CanonicalJSON.swift
//  LicenseSeatSDK
//
//  Created by LicenseSeat on 2025.
//  Copyright © 2025 LicenseSeat. All rights reserved.
//

import Foundation

/// Canonical JSON serializer for consistent signature verification
enum CanonicalJSON {
    
    /// Convert object to canonical JSON string
    static func stringify(_ object: Any) throws -> String {
        let canonicalObject = try canonicalize(object)
        let data = try JSONSerialization.data(
            withJSONObject: canonicalObject,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
        
        guard let string = String(data: data, encoding: .utf8) else {
            throw CanonicalJSONError.encodingFailed
        }
        
        return string
    }
    
    /// Recursively canonicalize an object
    private static func canonicalize(_ object: Any) throws -> Any {
        if let dictionary = object as? [String: Any] {
            // Sort dictionary keys
            var canonical: [String: Any] = [:]
            for key in dictionary.keys.sorted() {
                canonical[key] = try canonicalize(dictionary[key]!)
            }
            return canonical
            
        } else if let array = object as? [Any] {
            // Canonicalize array elements
            return try array.map { try canonicalize($0) }
            
        } else if let number = object as? NSNumber {
            // Normalize numbers
            return normalizeNumber(number)
            
        } else if object is NSNull {
            // Null is canonical
            return NSNull()
            
        } else if let string = object as? String {
            // Strings are canonical
            return string
            
        } else if let bool = object as? Bool {
            // Booleans are canonical
            return bool
            
        } else {
            throw CanonicalJSONError.unsupportedType(String(describing: type(of: object)))
        }
    }
    
    /// Normalize number representation
    private static func normalizeNumber(_ number: NSNumber) -> Any {
        // Check if it's a boolean disguised as NSNumber
        if CFBooleanGetTypeID() == CFGetTypeID(number) {
            return number.boolValue
        }
        
        // Check if it's an integer
        let double = number.doubleValue
        if double.truncatingRemainder(dividingBy: 1) == 0 && 
           double >= Double(Int64.min) && 
           double <= Double(Int64.max) {
            return number.int64Value
        }
        
        // Return as double
        return double
    }
}

/// Canonical JSON errors
enum CanonicalJSONError: LocalizedError {
    case encodingFailed
    case unsupportedType(String)
    
    var errorDescription: String? {
        switch self {
        case .encodingFailed:
            return "Failed to encode canonical JSON"
        case .unsupportedType(let type):
            return "Unsupported type for canonical JSON: \(type)"
        }
    }
} 