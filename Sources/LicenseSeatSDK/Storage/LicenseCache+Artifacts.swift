//
//  LicenseCache+Artifacts.swift
//  LicenseSeatSDK
//
//  Offline verification keys, rollback state, and grant cleanup.
//

import Foundation

extension LicenseCache {
    var licenseEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    var licenseDecoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    func getPublicKey(_ keyId: String) -> String? {
        guard validKeyId(keyId) else { return nil }
        return getPublicKeys()[keyId]
    }

    @discardableResult
    func setPublicKey(_ keyId: String, _ publicKey: String) -> Bool {
        guard validKeyId(keyId),
              publicKey.utf8.count <= 128,
              (try? Base64URL.decode(publicKey))?.count == 32 else {
            return false
        }
        var keys = getPublicKeys()
        guard keys[keyId] != nil || keys.count < Self.maxPublicKeys else {
            return false
        }
        keys[keyId] = publicKey

        guard let data = try? JSONSerialization.data(withJSONObject: keys),
              data.count <= Self.maxCacheBytes,
              storeProtectedData(data, forKey: Key.publicKeys) else { return false }
        removeLegacyData(forKey: Key.publicKeys)
        return true
    }

    private func getPublicKeys() -> [String: String] {
        guard let data = protectedData(forKey: Key.publicKeys),
              data.count <= Self.maxCacheBytes,
              (try? StrictJSON.validate(data, limits: .cache)) != nil,
              let keys = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {
            return [:]
        }
        guard keys.count <= Self.maxPublicKeys else { return [:] }
        return keys.filter {
            validKeyId($0.key) &&
                $0.value.utf8.count <= 128 &&
                (try? Base64URL.decode($0.value))?.count == 32
        }
    }

    func getLastSeenTimestamp() -> TimeInterval? {
        if let data = protectedData(forKey: Key.lastSeenTimestamp),
           let string = String(data: data, encoding: .utf8),
           let value = TimeInterval(string),
           value.isFinite,
           value > 0 {
            return value
        }

        let legacyValue = legacyPreferenceValue(forKey: Key.lastSeenTimestamp)
        guard legacyValue > 0 else { return nil }
        setLastSeenTimestamp(legacyValue)
        return legacyValue
    }

    /// Ratchet the clock watermark forward after offline verification.
    @discardableResult
    func setLastSeenTimestamp(_ timestamp: TimeInterval) -> Bool {
        guard timestamp.isFinite, timestamp > 0 else { return false }

        let protectedValue = readProtectedData(forKey: Key.lastSeenTimestamp)
            .flatMap { String(data: $0, encoding: .utf8) }
            .flatMap(TimeInterval.init)
        let legacyProtectedValue = readLegacyProtectedData(
            forKey: Key.lastSeenTimestamp
        )
            .flatMap { String(data: $0, encoding: .utf8) }
            .flatMap(TimeInterval.init)
        let legacyValue = legacyPreferenceValue(forKey: Key.lastSeenTimestamp)
        let protectedWatermark = protectedValue.flatMap {
            $0.isFinite && $0 > 0 ? $0 : nil
        } ?? 0
        let legacyWatermark = legacyValue.isFinite && legacyValue > 0 ? legacyValue : 0
        let legacyProtectedWatermark = legacyProtectedValue.flatMap {
            $0.isFinite && $0 > 0 ? $0 : nil
        } ?? 0
        let watermark = max(
            timestamp,
            max(protectedWatermark, max(legacyProtectedWatermark, legacyWatermark))
        )

        guard let data = String(watermark).data(using: .utf8),
              storeProtectedData(data, forKey: Key.lastSeenTimestamp) else {
            return false
        }
        removeLegacyData(forKey: Key.lastSeenTimestamp)
        return true
    }

    /// Re-anchor the rollback watermark after authoritative online acceptance.
    @discardableResult
    func anchorLastSeenTimestamp(_ timestamp: TimeInterval) -> Bool {
        guard timestamp.isFinite, timestamp > 0,
              let data = String(timestamp).data(using: .utf8),
              storeProtectedData(data, forKey: Key.lastSeenTimestamp) else {
            return false
        }
        removeLegacyData(forKey: Key.lastSeenTimestamp)
        return true
    }

    /// Clear grants while preserving the rollback watermark and installation ID.
    func clear() {
        for key in Key.clearedOnReset {
            deleteProtectedData(forKey: key)
            deleteLegacyProtectedData(forKey: key)
            userDefaults.removeObject(forKey: prefixed(key))
            if let legacyKey = legacyPrefixed(key) {
                userDefaults.removeObject(forKey: legacyKey)
            }
        }
        if let url = licenseFileURL {
            try? fileManager.removeItem(at: url)
        }
    }
}
