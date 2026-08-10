//
//  DecodingCompatibility.swift
//  LicenseSeatSDK
//
//  Compatibility decoding for identifier and fingerprint wire aliases.
//

import Foundation

extension KeyedDecodingContainer {
    func decodeStringOrInteger(forKey key: Key) throws -> String {
        if let string = try? decode(String.self, forKey: key) {
            return string
        }
        if let integer = try? decode(Int.self, forKey: key) {
            return String(integer)
        }

        throw DecodingError.typeMismatch(
            String.self,
            DecodingError.Context(
                codingPath: codingPath + [key],
                debugDescription: "Expected a string or integer identifier"
            )
        )
    }

    func decodeFirstPresentString(forKeys keys: [Key]) throws -> String {
        if let value = try decodeFirstPresentStringIfPresent(forKeys: keys) {
            return value
        }

        let key = keys[0]
        throw DecodingError.keyNotFound(
            key,
            DecodingError.Context(
                codingPath: codingPath,
                debugDescription: "None of the compatible device fingerprint fields were present"
            )
        )
    }

    func decodeFirstPresentStringIfPresent(forKeys keys: [Key]) throws -> String? {
        for key in keys where contains(key) {
            guard try !decodeNil(forKey: key) else { continue }
            return try decode(String.self, forKey: key)
        }
        return nil
    }
}
