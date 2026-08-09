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

/// Cache manager for license data
final class LicenseCache {
    private static let maxCacheBytes = 2 * 1024 * 1024

    private let preferencesPrefix: String
    private let fileStem: String
    private let userDefaults: UserDefaults
    private let fileManager = FileManager.default
    private let cacheDirectory: URL?

    init(prefix: String, userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        let prefixData = Data(prefix.utf8)
        let digest = SHA256.hash(data: prefixData).map { String(format: "%02x", $0) }.joined()
        self.fileStem = "licenseseat-\(digest)"
        if !prefix.isEmpty,
           prefix.utf8.count <= 128,
           prefix.unicodeScalars.allSatisfy({ $0.value > 31 && $0.value != 127 }) {
            self.preferencesPrefix = prefix
        } else {
            self.preferencesPrefix = "licenseseat_\(digest)_"
        }

        // Use Application Support directory for file storage (proper location for app data)
        // Falls back to Documents if Application Support is unavailable
        if let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            let bundleId = Bundle.main.bundleIdentifier ?? "com.licenseseat.sdk"
            let sdkDir = appSupport
                .appendingPathComponent(bundleId, isDirectory: true)
                .appendingPathComponent("LicenseSeat", isDirectory: true)

            // Create directory if needed
            try? fileManager.createDirectory(
                at: sdkDir,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try? fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: sdkDir.path)
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
        if let data = secureData(at: licenseFileURL),
           let license = try? licenseDecoder.decode(License.self, from: data) {
            return license
        }

        // One-way migration from older SDK releases, which persisted the
        // license credential in UserDefaults.
        let legacyKey = preferencesPrefix + "license"
        guard let data = userDefaults.data(forKey: legacyKey),
              data.count <= Self.maxCacheBytes,
              let license = try? licenseDecoder.decode(License.self, from: data) else {
            return nil
        }
        writeSecurely(data, to: licenseFileURL)
        userDefaults.removeObject(forKey: legacyKey)
        return license
    }

    func setLicense(_ license: License) {
        do {
            let data = try licenseEncoder.encode(license)

            guard data.count <= Self.maxCacheBytes else { return }
            writeSecurely(data, to: licenseFileURL)
            userDefaults.removeObject(forKey: preferencesPrefix + "license")
        } catch {
            #if DEBUG
            print("[LicenseCache] Failed to encode license (\(String(describing: type(of: error))))")
            #endif
        }
    }
    
    func updateValidation(_ validation: ValidationResponse, markValidatedOnline: Bool = true) {
        guard var license = getLicense() else { return }
        license.validation = validation
        if markValidatedOnline {
            license.lastValidated = Date()
        }
        setLicense(license)
    }

    func getDeviceId() -> String? {
        return getLicense()?.deviceId
    }
    
    func clearLicense() {
        userDefaults.removeObject(forKey: preferencesPrefix + "license")
        if let url = licenseFileURL {
            try? fileManager.removeItem(at: url)
        }
    }
    
    // MARK: - Offline Token Storage

    func getOfflineToken() -> OfflineTokenResponse? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let data = secureData(at: offlineTokenFileURL),
           let token = try? decoder.decode(OfflineTokenResponse.self, from: data) {
            return token
        }

        let legacyKey = preferencesPrefix + "offline_token"
        guard let data = userDefaults.data(forKey: legacyKey),
              data.count <= Self.maxCacheBytes,
              let token = try? decoder.decode(OfflineTokenResponse.self, from: data) else {
            return nil
        }
        writeSecurely(data, to: offlineTokenFileURL)
        userDefaults.removeObject(forKey: legacyKey)
        return token
    }

    func setOfflineToken(_ token: OfflineTokenResponse) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(token), data.count <= Self.maxCacheBytes else { return }
        writeSecurely(data, to: offlineTokenFileURL)
        userDefaults.removeObject(forKey: preferencesPrefix + "offline_token")
    }

    func clearOfflineToken() {
        userDefaults.removeObject(forKey: preferencesPrefix + "offline_token")
        if let url = offlineTokenFileURL {
            try? fileManager.removeItem(at: url)
        }
    }
    
    // MARK: - Public Key Storage
    
    func getPublicKey(_ keyId: String) -> String? {
        let keys = getPublicKeys()
        return keys[keyId]
    }
    
    func setPublicKey(_ keyId: String, _ publicKey: String) {
        var keys = getPublicKeys()
        keys[keyId] = publicKey
        
        if let data = try? JSONSerialization.data(withJSONObject: keys) {
            userDefaults.set(data, forKey: preferencesPrefix + "public_keys")
        }
    }
    
    private func getPublicKeys() -> [String: String] {
        guard let data = userDefaults.data(forKey: preferencesPrefix + "public_keys"),
              data.count <= Self.maxCacheBytes,
              let keys = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {
            return [:]
        }
        return keys
    }
    
    // MARK: - Timestamp Storage
    
    func getLastSeenTimestamp() -> TimeInterval? {
        let value = userDefaults.double(forKey: preferencesPrefix + "last_seen_ts")
        return value > 0 ? value : nil
    }
    
    func setLastSeenTimestamp(_ timestamp: TimeInterval) {
        guard timestamp.isFinite, timestamp > 0 else { return }
        userDefaults.set(timestamp, forKey: preferencesPrefix + "last_seen_ts")
    }
    
    // MARK: - Clear All
    
    func clear() {
        // Remove all keys with prefix
        let keys = userDefaults.dictionaryRepresentation().keys
        for key in keys {
            if key.hasPrefix(preferencesPrefix) {
                userDefaults.removeObject(forKey: key)
            }
        }
        
        // Clear file storage
        if let url = licenseFileURL {
            try? fileManager.removeItem(at: url)
        }
        if let url = offlineTokenFileURL {
            try? fileManager.removeItem(at: url)
        }
    }
    
    // MARK: - Private Helpers
    
    private var licenseFileURL: URL? {
        return cacheDirectory?.appendingPathComponent(fileStem + "-license.json")
    }

    private var offlineTokenFileURL: URL? {
        return cacheDirectory?.appendingPathComponent(fileStem + "-offline-token.json")
    }

    private func secureData(at url: URL?) -> Data? {
        guard let url = url,
              let attributes = try? fileManager.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber,
              size.intValue <= Self.maxCacheBytes,
              size.intValue >= 0 else {
            return nil
        }
        return try? Data(contentsOf: url, options: [.mappedIfSafe])
    }

    private func writeSecurely(_ data: Data, to url: URL?) {
        guard let url = url, data.count <= Self.maxCacheBytes else { return }
        do {
            try data.write(to: url, options: [.atomic])
            var attributes: [FileAttributeKey: Any] = [.posixPermissions: 0o600]
            #if os(iOS) || os(tvOS) || os(watchOS) || os(visionOS)
            attributes[.protectionKey] = FileProtectionType.completeUntilFirstUserAuthentication
            #endif
            try fileManager.setAttributes(attributes, ofItemAtPath: url.path)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var mutableURL = url
            try mutableURL.setResourceValues(values)
        } catch {
            #if DEBUG
            print("[LicenseCache] Failed to persist protected cache data (\(String(describing: type(of: error))))")
            #endif
        }
    }
}
