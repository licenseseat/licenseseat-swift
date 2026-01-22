//
//  LicenseCache.swift
//  LicenseSeatSDK
//
//  Created by LicenseSeat on 2025.
//  Copyright © 2025 LicenseSeat. All rights reserved.
//

import Foundation

/// Cache manager for license data
final class LicenseCache {
    private let prefix: String
    private let userDefaults: UserDefaults
    private let fileManager = FileManager.default
    private let cacheDirectory: URL?

    init(prefix: String, userDefaults: UserDefaults = .standard) {
        self.prefix = prefix
        self.userDefaults = userDefaults

        // Use Application Support directory for file storage (proper location for app data)
        // Falls back to Documents if Application Support is unavailable
        if let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            let bundleId = Bundle.main.bundleIdentifier ?? "com.licenseseat.sdk"
            let sdkDir = appSupport.appendingPathComponent(bundleId, isDirectory: true)

            // Create directory if needed
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
        // Try UserDefaults first
        if let data = userDefaults.data(forKey: prefix + "license") {
            return try? licenseDecoder.decode(License.self, from: data)
        }

        // Fallback to file storage
        guard let url = licenseFileURL else { return nil }
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? licenseDecoder.decode(License.self, from: data)
    }

    func setLicense(_ license: License) {
        do {
            let data = try licenseEncoder.encode(license)

            // Save to UserDefaults
            userDefaults.set(data, forKey: prefix + "license")
            userDefaults.synchronize() // Force sync for CLI tools

            // Also save to file
            if let url = licenseFileURL {
                try data.write(to: url, options: .atomic)
            }
        } catch {
            #if DEBUG
            print("[LicenseCache] Failed to encode license: \(error)")
            #endif
        }
    }
    
    func updateValidation(_ validation: ValidationResponse) {
        guard var license = getLicense() else { return }
        license.validation = validation
        license.lastValidated = Date()
        setLicense(license)
    }

    func getDeviceId() -> String? {
        return getLicense()?.deviceId
    }
    
    func clearLicense() {
        userDefaults.removeObject(forKey: prefix + "license")
        if let url = licenseFileURL {
            try? fileManager.removeItem(at: url)
        }
    }
    
    // MARK: - Offline Token Storage

    func getOfflineToken() -> OfflineTokenResponse? {
        guard let data = userDefaults.data(forKey: prefix + "offline_token") else {
            return nil
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(OfflineTokenResponse.self, from: data)
    }

    func setOfflineToken(_ token: OfflineTokenResponse) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(token) else { return }
        userDefaults.set(data, forKey: prefix + "offline_token")
    }

    func clearOfflineToken() {
        userDefaults.removeObject(forKey: prefix + "offline_token")
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
            userDefaults.set(data, forKey: prefix + "public_keys")
        }
    }
    
    private func getPublicKeys() -> [String: String] {
        guard let data = userDefaults.data(forKey: prefix + "public_keys"),
              let keys = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {
            return [:]
        }
        return keys
    }
    
    // MARK: - Timestamp Storage
    
    func getLastSeenTimestamp() -> TimeInterval? {
        let value = userDefaults.double(forKey: prefix + "last_seen_ts")
        return value > 0 ? value : nil
    }
    
    func setLastSeenTimestamp(_ timestamp: TimeInterval) {
        userDefaults.set(timestamp, forKey: prefix + "last_seen_ts")
    }
    
    // MARK: - Clear All
    
    func clear() {
        // Remove all keys with prefix
        let keys = userDefaults.dictionaryRepresentation().keys
        for key in keys {
            if key.hasPrefix(prefix) {
                userDefaults.removeObject(forKey: key)
            }
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
} 