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

    #if canImport(Security) && DEBUG
    /// Test-only override for the `SecItemCopyMatching` status so unit tests
    /// can simulate a locked or denied Keychain (`errSecInteractionNotAllowed`,
    /// `errSecAuthFailed`, ...) without entitlement-dependent state.
    nonisolated(unsafe) static var keychainReadStatusOverrideForTesting: OSStatus?
    #endif

    /// Return the stable installation identifier, creating one only when no
    /// identity exists yet.
    ///
    /// - Throws: ``LicenseSeatError/deviceIdentifierError`` when a protected
    ///   identity may exist but is temporarily unreadable (for example a
    ///   locked Keychain). Callers must surface this as a recoverable
    ///   condition — generating a replacement UUID instead would rotate the
    ///   installation fingerprint and consume another licensed seat.
    static func generate(
        userDefaults: UserDefaults = .standard,
        keychainServiceSuffix: String = ""
    ) throws -> String {
        if let cached = try getCachedIdentifier(
            userDefaults: userDefaults,
            keychainServiceSuffix: keychainServiceSuffix
        ) {
            return cached
        }

        let identifier = "\(platformPrefix)-\(UUID().uuidString.lowercased())"
        try cacheIdentifier(
            identifier,
            userDefaults: userDefaults,
            keychainServiceSuffix: keychainServiceSuffix
        )
        return identifier
    }

    /// Preserve the exact installation identity already bound to a cached
    /// activation. This lets clients stop supplying a legacy hardware-derived
    /// override without consuming a new seat after that activation is later
    /// deactivated or replaced.
    static func adoptCachedLicenseIdentifier(
        _ identifier: String,
        userDefaults: UserDefaults = .standard,
        keychainServiceSuffix: String = ""
    ) {
        guard !identifier.isEmpty else { return }
        // Best effort: the identity source is the cached activation itself,
        // so a transiently denied Keychain write cannot rotate anything.
        // Adoption re-runs on the next launch; it must never fail SDK
        // initialization.
        try? cacheIdentifier(
            identifier,
            userDefaults: userDefaults,
            keychainServiceSuffix: keychainServiceSuffix
        )
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
    ) throws -> String? {
        #if canImport(Security)
        if let protectedIdentifier = try readKeychainIdentifier(
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
            ) == errSecSuccess {
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
    ) throws {
        #if canImport(Security)
        switch storeKeychainIdentifier(
            identifier,
            keychainServiceSuffix: keychainServiceSuffix
        ) {
        case errSecSuccess:
            userDefaults.removeObject(forKey: cacheKey)
        case errSecInteractionNotAllowed, errSecAuthFailed, errSecUserCanceled:
            // The Keychain exists but temporarily refused the write (locked
            // keychain, denied prompt). Falling back to UserDefaults here
            // would mint an identity that the protected copy later
            // contradicts, rotating the fingerprint and consuming another
            // seat. Fail so the caller can retry once the keychain unlocks.
            throw LicenseSeatError.deviceIdentifierError
        default:
            // Keychain genuinely unavailable or misconfigured for this
            // process (for example a missing entitlement in a CI sandbox).
            // A deterministic UserDefaults identity is more important than
            // silently changing fingerprints on every launch.
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

    /// Read the protected installation identifier.
    ///
    /// Only `errSecItemNotFound` means "no identity exists yet". Any other
    /// failure (locked keychain: `errSecInteractionNotAllowed`, failed
    /// authorization: `errSecAuthFailed`, ...) means an identity may exist
    /// but is temporarily unreadable — treating it as absent would generate
    /// a replacement UUID, rotate the installation fingerprint, and consume
    /// another licensed seat. Identity acquisition fails instead so the host
    /// app can ask the user to unlock the keychain and retry.
    private static func readKeychainIdentifier(
        keychainServiceSuffix: String
    ) throws -> String? {
        var query = keychainQuery(keychainServiceSuffix: keychainServiceSuffix)
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status: OSStatus
        #if DEBUG
        if let override = keychainReadStatusOverrideForTesting {
            status = override
        } else {
            status = SecItemCopyMatching(query as CFDictionary, &result)
        }
        #else
        status = SecItemCopyMatching(query as CFDictionary, &result)
        #endif

        switch status {
        case errSecSuccess:
            guard let data = result as? Data,
                  let identifier = String(data: data, encoding: .utf8),
                  !identifier.isEmpty else {
                // A readable-but-malformed record is corruption, not a
                // transient denial; regenerating is the only way forward.
                return nil
            }
            return identifier
        case errSecItemNotFound:
            return nil
        default:
            throw LicenseSeatError.deviceIdentifierError
        }
    }

    private static func storeKeychainIdentifier(
        _ identifier: String,
        keychainServiceSuffix: String
    ) -> OSStatus {
        guard !identifier.isEmpty,
              let data = identifier.data(using: .utf8) else { return errSecParam }

        let query = keychainQuery(keychainServiceSuffix: keychainServiceSuffix)
        let updateStatus = SecItemUpdate(
            query as CFDictionary,
            [kSecValueData: data] as CFDictionary
        )
        if updateStatus == errSecSuccess { return updateStatus }
        guard updateStatus == errSecItemNotFound else { return updateStatus }

        var newItem = query
        newItem[kSecValueData] = data
        newItem[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(newItem as CFDictionary, nil)
    }
    #endif
}
