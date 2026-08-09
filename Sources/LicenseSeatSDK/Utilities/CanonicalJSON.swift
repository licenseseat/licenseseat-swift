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
    private static let maxDepth = 20
    private static let maxNodes = 10_000
    private static let maxKeyBytes = 256
    private static let maxStringBytes = 64 * 1024
    private static let maxCanonicalBytes = 1024 * 1024
    
    /// Convert object to canonical JSON string
    static func stringify(_ object: Any) throws -> String {
        var nodes = 0
        let canonicalObject = try canonicalize(object, depth: 0, nodes: &nodes)
        let data = try JSONSerialization.data(
            withJSONObject: canonicalObject,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
        guard data.count <= maxCanonicalBytes else {
            throw CanonicalJSONError.sizeLimitExceeded
        }
        
        guard let string = String(data: data, encoding: .utf8) else {
            throw CanonicalJSONError.encodingFailed
        }
        
        return string
    }
    
    /// Recursively canonicalize an object
    private static func canonicalize(_ object: Any, depth: Int, nodes: inout Int) throws -> Any {
        guard depth <= maxDepth else { throw CanonicalJSONError.depthLimitExceeded }
        nodes += 1
        guard nodes <= maxNodes else { throw CanonicalJSONError.nodeLimitExceeded }

        if let dictionary = object as? [String: Any] {
            // Sort dictionary keys
            var canonical: [String: Any] = [:]
            for key in dictionary.keys.sorted() {
                guard key.utf8.count <= maxKeyBytes else { throw CanonicalJSONError.sizeLimitExceeded }
                canonical[key] = try canonicalize(dictionary[key]!, depth: depth + 1, nodes: &nodes)
            }
            return canonical
            
        } else if let array = object as? [Any] {
            // Canonicalize array elements
            return try array.map { try canonicalize($0, depth: depth + 1, nodes: &nodes) }
            
        } else if let number = object as? NSNumber {
            // Normalize numbers
            return try normalizeNumber(number)
            
        } else if object is NSNull {
            // Null is canonical
            return NSNull()
            
        } else if let string = object as? String {
            // Strings are canonical
            guard string.utf8.count <= maxStringBytes else { throw CanonicalJSONError.sizeLimitExceeded }
            return string
            
        } else if let bool = object as? Bool {
            // Booleans are canonical
            return bool
            
        } else {
            throw CanonicalJSONError.unsupportedType(String(describing: type(of: object)))
        }
    }
    
    /// Normalize number representation
    private static func normalizeNumber(_ number: NSNumber) throws -> Any {
        // Check if it's a boolean disguised as NSNumber
#if canImport(CoreFoundation)
        if CFBooleanGetTypeID() == CFGetTypeID(number) {
            return number.boolValue
        }
#else
        // On platforms without CoreFoundation, fall back to inspecting the ObjC type.
        // A boolean NSNumber uses the "c" (char) objCType and only ever stores 0/1.
        if let cString = String(validatingUTF8: number.objCType), cString == "c" {
            return number.boolValue
        }
#endif
        
        // Check if it's an integer
        let double = number.doubleValue
        guard double.isFinite else { throw CanonicalJSONError.nonFiniteNumber }
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
    case depthLimitExceeded
    case nodeLimitExceeded
    case sizeLimitExceeded
    case nonFiniteNumber
    
    var errorDescription: String? {
        switch self {
        case .encodingFailed:
            return "Failed to encode canonical JSON"
        case .unsupportedType(let type):
            return "Unsupported type for canonical JSON: \(type)"
        case .depthLimitExceeded:
            return "Canonical JSON nesting is too deep"
        case .nodeLimitExceeded:
            return "Canonical JSON contains too many values"
        case .sizeLimitExceeded:
            return "Canonical JSON exceeds the supported size"
        case .nonFiniteNumber:
            return "Canonical JSON numbers must be finite"
        }
    }
}
