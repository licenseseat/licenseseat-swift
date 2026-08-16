//
//  LicenseCache.swift
//  LicenseSeatSDK
//
//  Created by LicenseSeat on 2025.
//  Copyright © 2025 LicenseSeat. All rights reserved.
//

import Foundation
#if canImport(CryptoKit)
import CryptoKit
#elseif canImport(Crypto)
import Crypto
#endif
#if canImport(Security)
import Security
#endif

/// Cache manager for license data
final class LicenseCache {
    static let maxCacheBytes = 2 * 1024 * 1024
    static let maxPublicKeys = 64

    enum Key {
        static let license = "license"
        static let offlineToken = "offline_token"
        static let machineFile = "machine_file"
        static let publicKeys = "public_keys"
        static let lastSeenTimestamp = "last_seen_ts"

        /// Records deleted by `clear()`.
        ///
        /// The clock-rollback watermark (`lastSeenTimestamp`) deliberately
        /// survives `clear()`/reset, exactly like the installation identifier:
        /// a local reset combined with a clock rollback and re-imported,
        /// previously exported signed artifact files must not extend an
        /// offline window. License and artifact grants die here, so keeping
        /// the watermark costs nothing; it is re-anchored (and may move
        /// backward) only by an authoritative online operation — see
        /// `anchorLastSeenTimestamp(_:)`. This contract is shared with the
        /// other LicenseSeat SDKs.
        static let clearedOnReset = [license, offlineToken, machineFile, publicKeys]
    }

    /// New storage is always addressed by a fixed-length digest. The
    /// caller-controlled compatibility prefix is never used as a path
    /// component or an unbounded Keychain/UserDefaults account.
    let namespacePrefix: String
    let legacyPreferencesPrefix: String?
    let legacyFilePrefix: String?
    let userDefaults: UserDefaults
    let fileManager = FileManager.default
    let cacheDirectory: URL?
    #if canImport(Security)
    let keychainService: String
    #endif

    init(prefix: String, userDefaults: UserDefaults = .standard) {
        let digest = SHA256.hash(data: Data(prefix.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        self.namespacePrefix = "licenseseat_\(digest)_"
        if !prefix.isEmpty,
           prefix.utf8.count <= 128,
           prefix.unicodeScalars.allSatisfy({
               $0.value > 31 && $0.value != 127
           }) {
            self.legacyPreferencesPrefix = prefix
        } else {
            self.legacyPreferencesPrefix = nil
        }
        if prefix.range(
            of: "^[A-Za-z0-9_-][A-Za-z0-9._-]{0,127}$",
            options: .regularExpression
        ) != nil {
            self.legacyFilePrefix = prefix
        } else {
            self.legacyFilePrefix = nil
        }
        self.userDefaults = userDefaults

        let bundleId = Bundle.main.bundleIdentifier ?? "com.licenseseat.sdk"
        #if canImport(Security)
        self.keychainService = "\(bundleId).LicenseSeat"
        #endif

        // Retain the historical file location only for one-time migration.
        // New Apple-platform writes go exclusively to the Keychain.
        if let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            let sdkDir = appSupport.appendingPathComponent(bundleId, isDirectory: true)

            try? fileManager.createDirectory(
                at: sdkDir,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            self.cacheDirectory = sdkDir
        } else {
            // Fallback to caches directory
            self.cacheDirectory = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first
        }
    }
    
    // MARK: - License Storage

    func getLicense() -> License? {
        guard let data = protectedData(forKey: Key.license, legacyFileURL: licenseFileURL) else {
            return nil
        }
        guard data.count <= Self.maxCacheBytes,
              (try? StrictJSON.validate(data, limits: .cache)) != nil else {
            return nil
        }
        return try? licenseDecoder.decode(License.self, from: data)
    }

    @discardableResult
    func setLicense(_ license: License) -> Bool {
        do {
            let data = try licenseEncoder.encode(license)
            guard data.count <= Self.maxCacheBytes,
                  storeProtectedData(data, forKey: Key.license) else {
                return false
            }
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
    func updateValidation(
        _ validation: ValidationResponse,
        markValidatedOnline: Bool = true
    ) -> Bool {
        guard var license = getLicense() else { return false }
        license.validation = validation
        if markValidatedOnline {
            license.lastValidated = Date()
        }
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
        guard data.count <= Self.maxCacheBytes,
              (try? StrictJSON.validate(data, limits: .cache)) != nil else {
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
        guard let data = try? encoder.encode(token),
              data.count <= Self.maxCacheBytes else {
            return false
        }
        guard storeProtectedData(data, forKey: Key.offlineToken) else { return false }
        removeLegacyData(forKey: Key.offlineToken)
        return true
    }

    func clearOfflineToken() {
        deleteProtectedData(forKey: Key.offlineToken)
        removeLegacyData(forKey: Key.offlineToken)
    }

    // MARK: - Private Helpers
    
    var licenseFileURL: URL? {
        guard let legacyFilePrefix else { return nil }
        return cacheDirectory?.appendingPathComponent(
            legacyFilePrefix + "license.json",
            isDirectory: false
        )
    }

    func prefixed(_ key: String) -> String {
        namespacePrefix + key
    }

    func legacyPrefixed(_ key: String) -> String? {
        legacyPreferencesPrefix.map { $0 + key }
    }

    func legacyPreferenceValue(forKey key: String) -> TimeInterval {
        guard let legacyKey = legacyPrefixed(key) else { return 0 }
        return userDefaults.double(forKey: legacyKey)
    }

    func validKeyId(_ keyId: String) -> Bool {
        keyId.utf8.count <= 255 &&
            keyId.range(
                of: "^[A-Za-z0-9][A-Za-z0-9._:-]*$",
                options: .regularExpression
            ) != nil
    }

    /// Reads protected storage and migrates the plaintext 0.4.x locations on
    /// first access. Plaintext is removed only after the protected write has
    /// succeeded, so an interrupted migration never loses an activation.
    func protectedData(forKey key: String, legacyFileURL: URL? = nil) -> Data? {
        if let data = readProtectedData(forKey: key),
           data.count <= Self.maxCacheBytes {
            return data
        }

        let legacyData = readLegacyProtectedData(forKey: key)
            ?? legacyPrefixed(key).flatMap { userDefaults.data(forKey: $0) }
            ?? boundedLegacyFileData(at: legacyFileURL)
        guard let legacyData,
              legacyData.count <= Self.maxCacheBytes else {
            return nil
        }

        if storeProtectedData(legacyData, forKey: key) {
            removeLegacyData(forKey: key, fileURL: legacyFileURL)
        }
        return legacyData
    }

    func removeLegacyData(forKey key: String, fileURL: URL? = nil) {
        deleteLegacyProtectedData(forKey: key)
        if let legacyKey = legacyPrefixed(key) {
            userDefaults.removeObject(forKey: legacyKey)
        }
        if let fileURL {
            try? fileManager.removeItem(at: fileURL)
        }
    }

    private func boundedLegacyFileData(at url: URL?) -> Data? {
        guard let url,
              fileManager.fileExists(atPath: url.path),
              let values = try? url.resourceValues(
                  forKeys: [
                      .isSymbolicLinkKey,
                      .isRegularFileKey,
                      .fileSizeKey
                  ]
              ),
              values.isSymbolicLink != true,
              values.isRegularFile == true,
              let size = values.fileSize,
              size >= 0,
              size <= Self.maxCacheBytes else {
            return nil
        }
        return try? Data(contentsOf: url, options: [.mappedIfSafe])
    }

    #if canImport(Security)
    private func keychainQuery(forKey key: String) -> [CFString: Any] {
        [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: keychainService,
            kSecAttrAccount: prefixed(key)
        ]
    }

    private func legacyKeychainQuery(forKey key: String) -> [CFString: Any]? {
        guard let account = legacyPrefixed(key),
              account != prefixed(key) else {
            return nil
        }
        return [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: keychainService,
            kSecAttrAccount: account
        ]
    }

    func readProtectedData(forKey key: String) -> Data? {
        var query = keychainQuery(forKey: key)
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else { return nil }
        return result as? Data
    }

    func readLegacyProtectedData(forKey key: String) -> Data? {
        guard var query = legacyKeychainQuery(forKey: key) else {
            return nil
        }
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else { return nil }
        return result as? Data
    }

    @discardableResult
    func storeProtectedData(_ data: Data, forKey key: String) -> Bool {
        guard data.count <= Self.maxCacheBytes else { return false }
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

    func deleteProtectedData(forKey key: String) {
        let status = SecItemDelete(keychainQuery(forKey: key) as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            logKeychainFailure(status, operation: "delete", key: key)
        }
    }

    func deleteLegacyProtectedData(forKey key: String) {
        guard let query = legacyKeychainQuery(forKey: key) else { return }
        let status = SecItemDelete(query as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            logKeychainFailure(status, operation: "delete legacy", key: key)
        }
    }

    private func logKeychainFailure(_ status: OSStatus, operation: String, key: String) {
        #if DEBUG
        print("[LicenseCache] Keychain \(operation) failed for \(key) (OSStatus \(status))")
        #endif
    }
    #else
    func readProtectedData(forKey key: String) -> Data? {
        userDefaults.data(forKey: prefixed(key))
    }

    func readLegacyProtectedData(forKey key: String) -> Data? {
        guard let legacyKey = legacyPrefixed(key) else { return nil }
        return userDefaults.data(forKey: legacyKey)
    }

    @discardableResult
    func storeProtectedData(_ data: Data, forKey key: String) -> Bool {
        guard data.count <= Self.maxCacheBytes else { return false }
        userDefaults.set(data, forKey: prefixed(key))
        return true
    }

    func deleteProtectedData(forKey key: String) {
        userDefaults.removeObject(forKey: prefixed(key))
    }

    func deleteLegacyProtectedData(forKey key: String) {
        guard let legacyKey = legacyPrefixed(key) else { return }
        userDefaults.removeObject(forKey: legacyKey)
    }
    #endif
}
