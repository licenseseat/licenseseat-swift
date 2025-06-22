//
//  LicenseSeat+OfflineValidation.swift
//  LicenseSeatSDK
//
//  Created by LicenseSeat on 2025.
//  Copyright © 2025 LicenseSeat. All rights reserved.
//

import Foundation
// Prefer system CryptoKit; fallback to SwiftCrypto on platforms where it is unavailable (e.g. Linux)
#if canImport(CryptoKit)
import CryptoKit
#elseif canImport(Crypto)
import Crypto
#endif

extension LicenseSeat {
    
    /// Verify cached offline license and return validation result
    func verifyCachedOffline() async -> LicenseValidationResult {
        guard let signedLicense = cache.getOfflineLicense() else {
            return LicenseValidationResult(
                valid: false,
                reason: nil,
                offline: true,
                reasonCode: "no_offline_license"
            )
        }
        
        let kid = signedLicense.kid ?? (signedLicense.payload?["kid"] as? String)
        var publicKey = kid.flatMap { cache.getPublicKey($0) }
        
        // Try to fetch public key if not cached
        if publicKey == nil, let kid = kid {
            do {
                publicKey = try await getPublicKey(keyId: kid)
                cache.setPublicKey(kid, publicKey!)
            } catch {
                return LicenseValidationResult(
                    valid: false,
                    reason: nil,
                    offline: true,
                    reasonCode: "no_public_key"
                )
            }
        }
        
        guard let publicKeyB64 = publicKey else {
            return LicenseValidationResult(
                valid: false,
                reason: nil,
                offline: true,
                reasonCode: "no_public_key"
            )
        }
        
        do {
            let isValid = try await verifyOfflineLicense(
                signedLicense,
                publicKeyB64: publicKeyB64
            )
            
            if !isValid {
                return LicenseValidationResult(
                    valid: false,
                    reason: nil,
                    offline: true,
                    reasonCode: "signature_invalid"
                )
            }
            
            // Payload sanity checks
            let payload = signedLicense.payload ?? [:]
            guard let cachedLicense = cache.getLicense() else {
                return LicenseValidationResult(
                    valid: false,
                    reason: nil,
                    offline: true,
                    reasonCode: "license_mismatch"
                )
            }
            
            // 1. License key match (constant-time comparison)
            let payloadLicenseKey = payload["lic_k"] as? String ?? ""
            if !constantTimeEqual(payloadLicenseKey, cachedLicense.licenseKey) {
                return LicenseValidationResult(
                    valid: false,
                    reason: nil,
                    offline: true,
                    reasonCode: "license_mismatch"
                )
            }
            
            // 2. Check expiry
            let now = Date()
            if let expAtString = payload["exp_at"] as? String,
               let expAt = ISO8601DateFormatter().date(from: expAtString) {
                if expAt < now {
                    return LicenseValidationResult(
                        valid: false,
                        reason: nil,
                        offline: true,
                        reasonCode: "expired"
                    )
                }
            } else if config.maxOfflineDays > 0 {
                // Grace period check
                let pivot = cachedLicense.lastValidated
                let ageInDays = Calendar.current.dateComponents(
                    [.day],
                    from: pivot,
                    to: now
                ).day ?? 0
                
                if ageInDays > config.maxOfflineDays {
                    return LicenseValidationResult(
                        valid: false,
                        reason: nil,
                        offline: true,
                        reasonCode: "grace_period_expired"
                    )
                }
            }
            
            // 3. Clock tamper detection
            if let lastSeenMs = cache.getLastSeenTimestamp() {
                let nowMs = now.timeIntervalSince1970
                if nowMs + (config.maxClockSkewMs / 1000) < lastSeenMs {
                    return LicenseValidationResult(
                        valid: false,
                        reason: nil,
                        offline: true,
                        reasonCode: "clock_tamper"
                    )
                }
            }
            
            // Update last seen timestamp
            cache.setLastSeenTimestamp(now.timeIntervalSince1970)
            
            // Extract active entitlements (if any)
            let activeEntitlements = parseActiveEntitlements(from: payload)
            
            return LicenseValidationResult(
                valid: true,
                reason: nil,
                offline: true,
                reasonCode: nil,
                optimistic: nil,
                activeEntitlements: activeEntitlements.isEmpty ? nil : activeEntitlements
            )
            
        } catch {
            return LicenseValidationResult(
                valid: false,
                reason: nil,
                offline: true,
                reasonCode: "verification_error"
            )
        }
    }
    
    /// Quick local offline verification (no network calls)
    func quickVerifyCachedOfflineLocal() async -> LicenseValidationResult? {
        guard let signedLicense = cache.getOfflineLicense() else { return nil }
        
        let kid = signedLicense.kid ?? (signedLicense.payload?["kid"] as? String)
        guard let kid = kid,
              let publicKey = cache.getPublicKey(kid) else { return nil }
        
        do {
            let isValid = try await verifyOfflineLicense(
                signedLicense,
                publicKeyB64: publicKey
            )
            
            return LicenseValidationResult(
                valid: isValid,
                reason: nil,
                offline: true,
                reasonCode: isValid ? nil : "signature_invalid",
                optimistic: nil,
                activeEntitlements: (isValid ? parseActiveEntitlements(from: signedLicense.payload ?? [:]) : nil)
            )
        } catch {
            return LicenseValidationResult(
                valid: false,
                reason: nil,
                offline: true,
                reasonCode: "verification_error"
            )
        }
    }
    
    /// Verify offline license signature
    private func verifyOfflineLicense(
        _ signedLicense: OfflineLicense,
        publicKeyB64: String
    ) async throws -> Bool {
        log("Attempting to verify offline license client-side.")
        
        guard let payload = signedLicense.payload,
              let signatureB64U = signedLicense.signatureB64u else {
            throw LicenseSeatError.invalidOfflineLicense
        }
        
        #if canImport(CryptoKit) || canImport(Crypto)
        // Convert payload to canonical JSON
        let payloadString = try CanonicalJSON.stringify(payload)
        let messageData = Data(payloadString.utf8)
        
        // Decode public key
        let publicKeyData = try Base64URL.decode(publicKeyB64)
        let publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: publicKeyData)
        
        // Decode signature
        let signatureData = try Base64URL.decode(signatureB64U)
        
        // Verify
        let isValid = publicKey.isValidSignature(signatureData, for: messageData)
        
        if isValid {
            log("Offline license signature VERIFIED successfully client-side.")
            eventBus.emit("offlineLicense:verified", ["payload": payload])
        } else {
            log("Offline license signature INVALID client-side.")
            eventBus.emit("offlineLicense:verificationFailed", ["payload": payload])
        }
        
        return isValid
        #else
        // CryptoKit not available - can't verify
        log("CryptoKit not available for offline verification")
        eventBus.emit("sdk:error", [
            "message": "Client-side verification crypto not available"
        ])
        throw LicenseSeatError.cryptoUnavailable
        #endif
    }
    
    /// Constant-time string comparison
    private func constantTimeEqual(_ a: String, _ b: String) -> Bool {
        guard a.count == b.count else { return false }
        
        var result = 0
        for (charA, charB) in zip(a, b) {
            result |= Int(charA.asciiValue ?? 0) ^ Int(charB.asciiValue ?? 0)
        }
        
        return result == 0
    }
    
    // MARK: - Entitlement Parsing
    /// Build an array of `Entitlement` models from the offline license payload.
    /// - Parameter payload: Raw payload dictionary extracted from the signed offline license.
    /// - Returns: Array of entitlements (empty if none present).
    private func parseActiveEntitlements(from payload: [String: Any]) -> [Entitlement] {
        // Support both `active_ents` (short) and `active_entitlements` (long) keys
        let rawEntitlements = (payload["active_ents"] as? [[String: Any]]) ??
                              (payload["active_entitlements"] as? [[String: Any]]) ?? []
        guard !rawEntitlements.isEmpty else { return [] }
        
        let isoFormatter = ISO8601DateFormatter()
        
        return rawEntitlements.compactMap { item in
            guard let key = item["key"] as? String else { return nil }
            let name = item["name"] as? String
            let description = item["description"] as? String
            var expiresAt: Date? = nil
            if let expiresStr = item["expires_at"] as? String {
                expiresAt = isoFormatter.date(from: expiresStr)
            }
            var metadata: [String: AnyCodable]? = nil
            if let metaDict = item["metadata"] as? [String: Any] {
                metadata = metaDict.mapValues { AnyCodable($0) }
            }
            return Entitlement(
                key: key,
                name: name,
                description: description,
                expiresAt: expiresAt,
                metadata: metadata
            )
        }
    }
} 