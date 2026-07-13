//
//  LicenseCache.swift
//  LicenseSeatSDK
//
//  Created by LicenseSeat on 2025.
//  Copyright © 2025 LicenseSeat. All rights reserved.
//

import Foundation
#if canImport(Security)
import Security
#endif

/// Cache manager for license data
final class LicenseCache {
    private enum Key {
        static let license = "license"
        static let offlineToken = "offline_token"
        static let publicKeys = "public_keys"
        static let lastSeenTimestamp = "last_seen_ts"

        static let all = [license, offlineToken, publicKeys, lastSeenTimestamp]
    }

    private let prefix: String
    private let userDefaults: UserDefaults
    private let fileManager = FileManager.default
    private let cacheDirectory: URL?
    #if canImport(Security)
    private let keychainService: String
    #endif

    init(prefix: String, userDefaults: UserDefaults = .standard) {
        self.prefix = prefix
        self.userDefaults = userDefaults

        let bundleId = Bundle.main.bundleIdentifier ?? "com.licenseseat.sdk"
        #if canImport(Security)
        self.keychainService = "\(bundleId).LicenseSeat"
        #endif

        // Retain the historical file location only for one-time migration.
        // New Apple-platform writes go exclusively to the Keychain.
        if let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            let sdkDir = appSupport.appendingPathComponent(bundleId, isDirectory: true)

            try? fileManager.createDirectory(at: sdkDir, withIntermediateDirectories: true)
            self.cacheDirectory = sdkDir
        } else {
            // Fallback to caches directory
            self.cacheDirectory = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first
        }
    }
    
    // MARK: - License Storage

    private var licenseEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private var licenseDecoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    func getLicense() -> License? {
        guard let data = protectedData(forKey: Key.license, legacyFileURL: licenseFileURL) else {
            return nil
        }
        return try? licenseDecoder.decode(License.self, from: data)
    }

    @discardableResult
    func setLicense(_ license: License) -> Bool {
        do {
            let data = try licenseEncoder.encode(license)
            guard storeProtectedData(data, forKey: Key.license) else { return false }
            removeLegacyData(forKey: Key.license, fileURL: licenseFileURL)
            return true
        } catch {
            #if DEBUG
            print("[LicenseCache] Failed to encode license: \(error)")
            #endif
            return false
        }
    }
    
    @discardableResult
    func updateValidation(_ validation: ValidationResponse) -> Bool {
        guard var license = getLicense() else { return false }
        license.validation = validation
        license.lastValidated = Date()
        return setLicense(license)
    }

    func getDeviceId() -> String? {
        return getLicense()?.deviceId
    }
    
    func clearLicense() {
        deleteProtectedData(forKey: Key.license)
        removeLegacyData(forKey: Key.license, fileURL: licenseFileURL)
    }
    
    // MARK: - Offline Token Storage

    func getOfflineToken() -> OfflineTokenResponse? {
        guard let data = protectedData(forKey: Key.offlineToken) else {
            return nil
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(OfflineTokenResponse.self, from: data)
    }

    @discardableResult
    func setOfflineToken(_ token: OfflineTokenResponse) -> Bool {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(token) else { return false }
        guard storeProtectedData(data, forKey: Key.offlineToken) else { return false }
        removeLegacyData(forKey: Key.offlineToken)
        return true
    }

    func clearOfflineToken() {
        deleteProtectedData(forKey: Key.offlineToken)
        removeLegacyData(forKey: Key.offlineToken)
    }
    
    // MARK: - Public Key Storage
    
    func getPublicKey(_ keyId: String) -> String? {
        let keys = getPublicKeys()
        return keys[keyId]
    }
    
    @discardableResult
    func setPublicKey(_ keyId: String, _ publicKey: String) -> Bool {
        var keys = getPublicKeys()
        keys[keyId] = publicKey
        
        guard let data = try? JSONSerialization.data(withJSONObject: keys),
              storeProtectedData(data, forKey: Key.publicKeys) else { return false }
        removeLegacyData(forKey: Key.publicKeys)
        return true
    }

    private func getPublicKeys() -> [String: String] {
        guard let data = protectedData(forKey: Key.publicKeys),
              let keys = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {
            return [:]
        }
        return keys
    }
    
    // MARK: - Timestamp Storage
    
    func getLastSeenTimestamp() -> TimeInterval? {
        if let data = readProtectedData(forKey: Key.lastSeenTimestamp),
           let string = String(data: data, encoding: .utf8),
           let value = TimeInterval(string),
           value > 0 {
            return value
        }

        // Migrate the 0.4.x UserDefaults Double representation.
        let legacyValue = userDefaults.double(forKey: prefixed(Key.lastSeenTimestamp))
        guard legacyValue > 0 else { return nil }
        setLastSeenTimestamp(legacyValue)
        return legacyValue
    }

    @discardableResult
    func setLastSeenTimestamp(_ timestamp: TimeInterval) -> Bool {
        guard timestamp.isFinite, timestamp > 0 else { return false }

        // A successful online request must never move the clock-tamper
        // watermark backwards. Preserve the highest protected or legacy value
        // so a temporary clock rollback cannot extend an offline grant.
        let protectedValue = readProtectedData(forKey: Key.lastSeenTimestamp)
            .flatMap { String(data: $0, encoding: .utf8) }
            .flatMap(TimeInterval.init)
        let legacyValue = userDefaults.double(forKey: prefixed(Key.lastSeenTimestamp))
        let protectedWatermark = protectedValue.flatMap {
            $0.isFinite && $0 > 0 ? $0 : nil
        } ?? 0
        let legacyWatermark = legacyValue.isFinite && legacyValue > 0 ? legacyValue : 0
        let watermark = max(timestamp, max(protectedWatermark, legacyWatermark))

        guard let data = String(watermark).data(using: .utf8),
              storeProtectedData(data, forKey: Key.lastSeenTimestamp) else {
            return false
        }
        removeLegacyData(forKey: Key.lastSeenTimestamp)
        return true
    }
    
    // MARK: - Clear All
    
    func clear() {
        for key in Key.all {
            deleteProtectedData(forKey: key)
            // Remove the matching 0.4.x plaintext representation without
            // deleting other components' values that happen to share the
            // configured prefix. In particular, DeviceIdentifier owns the
            // stable installation fingerprint and reset must not rotate it or
            // consume another licensed seat.
            userDefaults.removeObject(forKey: prefixed(key))
        }
        
        // Clear file storage
        if let url = licenseFileURL {
            try? fileManager.removeItem(at: url)
        }
    }
    
    // MARK: - Private Helpers
    
    private var licenseFileURL: URL? {
        return cacheDirectory?.appendingPathComponent(prefix + "license.json")
    }

    private func prefixed(_ key: String) -> String {
        prefix + key
    }

    /// Reads protected storage and migrates the plaintext 0.4.x locations on
    /// first access. Plaintext is removed only after the protected write has
    /// succeeded, so an interrupted migration never loses an activation.
    private func protectedData(forKey key: String, legacyFileURL: URL? = nil) -> Data? {
        if let data = readProtectedData(forKey: key) {
            return data
        }

        let legacyData = userDefaults.data(forKey: prefixed(key))
            ?? legacyFileURL.flatMap { try? Data(contentsOf: $0) }
        guard let legacyData else { return nil }

        if storeProtectedData(legacyData, forKey: key) {
            removeLegacyData(forKey: key, fileURL: legacyFileURL)
        }
        return legacyData
    }

    private func removeLegacyData(forKey key: String, fileURL: URL? = nil) {
        #if canImport(Security)
        userDefaults.removeObject(forKey: prefixed(key))
        #endif
        if let fileURL {
            try? fileManager.removeItem(at: fileURL)
        }
    }

    #if canImport(Security)
    private func keychainQuery(forKey key: String) -> [CFString: Any] {
        [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: keychainService,
            kSecAttrAccount: prefixed(key)
        ]
    }

    private func readProtectedData(forKey key: String) -> Data? {
        var query = keychainQuery(forKey: key)
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else { return nil }
        return result as? Data
    }

    @discardableResult
    private func storeProtectedData(_ data: Data, forKey key: String) -> Bool {
        let query = keychainQuery(forKey: key)
        let updateStatus = SecItemUpdate(
            query as CFDictionary,
            [kSecValueData: data] as CFDictionary
        )
        if updateStatus == errSecSuccess {
            return true
        }

        guard updateStatus == errSecItemNotFound else {
            logKeychainFailure(updateStatus, operation: "update", key: key)
            return false
        }

        var newItem = query
        newItem[kSecValueData] = data
        newItem[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = SecItemAdd(newItem as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            logKeychainFailure(addStatus, operation: "add", key: key)
            return false
        }
        return true
    }

    private func deleteProtectedData(forKey key: String) {
        let status = SecItemDelete(keychainQuery(forKey: key) as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            logKeychainFailure(status, operation: "delete", key: key)
        }
    }

    private func logKeychainFailure(_ status: OSStatus, operation: String, key: String) {
        #if DEBUG
        print("[LicenseCache] Keychain \(operation) failed for \(key) (OSStatus \(status))")
        #endif
    }
    #else
    private func readProtectedData(forKey key: String) -> Data? {
        userDefaults.data(forKey: prefixed(key))
    }

    @discardableResult
    private func storeProtectedData(_ data: Data, forKey key: String) -> Bool {
        userDefaults.set(data, forKey: prefixed(key))
        return true
    }

    private func deleteProtectedData(forKey key: String) {
        userDefaults.removeObject(forKey: prefixed(key))
    }
    #endif
}
