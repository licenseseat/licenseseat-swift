//
//  DeviceIdentifier.swift
//  LicenseSeatSDK
//
//  Created by LicenseSeat on 2025.
//  Copyright © 2025 LicenseSeat. All rights reserved.
//

import Foundation
#if canImport(Security)
import Security
#endif

/// Generates a stable, app-scoped installation identifier.
///
/// The identifier is random rather than derived from hardware or mutable
/// device characteristics. Existing UserDefaults identifiers are migrated so
/// upgrades do not consume a new seat. Apple platforms protect new values in
/// Keychain; other platforms retain the UserDefaults compatibility store.
enum DeviceIdentifier {
    private static let cacheKey = "licenseseat_device_identifier"

    static func generate(
        userDefaults: UserDefaults = .standard,
        keychainServiceSuffix: String = ""
    ) -> String {
        if let cached = getCachedIdentifier(
            userDefaults: userDefaults,
            keychainServiceSuffix: keychainServiceSuffix
        ) {
            return cached
        }

        let identifier = "\(platformPrefix)-\(UUID().uuidString.lowercased())"
        cacheIdentifier(
            identifier,
            userDefaults: userDefaults,
            keychainServiceSuffix: keychainServiceSuffix
        )
        return identifier
    }

    private static var platformPrefix: String {
        #if os(macOS)
        return "mac"
        #elseif os(iOS) || os(tvOS)
        return "ios"
        #elseif os(watchOS)
        return "watch"
        #else
        return "swift"
        #endif
    }

    private static func getCachedIdentifier(
        userDefaults: UserDefaults,
        keychainServiceSuffix: String
    ) -> String? {
        #if canImport(Security)
        if let protectedIdentifier = readKeychainIdentifier(
            keychainServiceSuffix: keychainServiceSuffix
        ) {
            return protectedIdentifier
        }

        // Preserve the installation identity assigned by earlier SDKs. Remove
        // plaintext only after a successful protected write.
        if let legacyIdentifier = userDefaults.string(forKey: cacheKey),
           !legacyIdentifier.isEmpty {
            if storeKeychainIdentifier(
                legacyIdentifier,
                keychainServiceSuffix: keychainServiceSuffix
            ) {
                userDefaults.removeObject(forKey: cacheKey)
            }
            return legacyIdentifier
        }
        userDefaults.removeObject(forKey: cacheKey)
        return nil
        #else
        guard let identifier = userDefaults.string(forKey: cacheKey),
              !identifier.isEmpty else {
            userDefaults.removeObject(forKey: cacheKey)
            return nil
        }
        return identifier
        #endif
    }

    private static func cacheIdentifier(
        _ identifier: String,
        userDefaults: UserDefaults,
        keychainServiceSuffix: String
    ) {
        #if canImport(Security)
        if !storeKeychainIdentifier(
            identifier,
            keychainServiceSuffix: keychainServiceSuffix
        ) {
            // A usable installation identity is more important than silently
            // changing fingerprints on every launch when Keychain is
            // unavailable or misconfigured.
            userDefaults.set(identifier, forKey: cacheKey)
        }
        #else
        userDefaults.set(identifier, forKey: cacheKey)
        #endif
    }

    /// Clear the cached identifier for tests and explicit diagnostic recovery.
    static func clearCache(
        userDefaults: UserDefaults = .standard,
        keychainServiceSuffix: String = ""
    ) {
        userDefaults.removeObject(forKey: cacheKey)
        #if canImport(Security)
        SecItemDelete(
            keychainQuery(keychainServiceSuffix: keychainServiceSuffix) as CFDictionary
        )
        #endif
    }

    #if canImport(Security)
    private static func keychainQuery(
        keychainServiceSuffix: String
    ) -> [CFString: Any] {
        let bundleIdentifier = Bundle.main.bundleIdentifier ?? "com.licenseseat.sdk"
        return [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: "\(bundleIdentifier).LicenseSeat.DeviceIdentifier\(keychainServiceSuffix)",
            kSecAttrAccount: cacheKey
        ]
    }

    private static func readKeychainIdentifier(
        keychainServiceSuffix: String
    ) -> String? {
        var query = keychainQuery(keychainServiceSuffix: keychainServiceSuffix)
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne

        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let identifier = String(data: data, encoding: .utf8),
              !identifier.isEmpty else {
            return nil
        }
        return identifier
    }

    @discardableResult
    private static func storeKeychainIdentifier(
        _ identifier: String,
        keychainServiceSuffix: String
    ) -> Bool {
        guard !identifier.isEmpty,
              let data = identifier.data(using: .utf8) else { return false }

        let query = keychainQuery(keychainServiceSuffix: keychainServiceSuffix)
        let updateStatus = SecItemUpdate(
            query as CFDictionary,
            [kSecValueData: data] as CFDictionary
        )
        if updateStatus == errSecSuccess { return true }
        guard updateStatus == errSecItemNotFound else { return false }

        var newItem = query
        newItem[kSecValueData] = data
        newItem[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(newItem as CFDictionary, nil) == errSecSuccess
    }
    #endif
}
