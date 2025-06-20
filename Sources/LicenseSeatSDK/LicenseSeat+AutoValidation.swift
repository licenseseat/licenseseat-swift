//
//  LicenseSeat+AutoValidation.swift
//  LicenseSeatSDK
//
//  Created by LicenseSeat on 2025.
//  Copyright © 2025 LicenseSeat. All rights reserved.
//

import Foundation

extension LicenseSeat {
    
    /// Start automatic license validation
    /// - Parameter licenseKey: License key to validate periodically
    func startAutoValidation(licenseKey: String) {
        stopAutoValidation()
        
        currentAutoLicenseKey = licenseKey
        let interval = config.autoValidateInterval
        
        // Schedule validation timer
        validationTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.performAutoValidation(licenseKey: licenseKey)
            }
        }
        
        // Announce next scheduled run
        eventBus.emit("autovalidation:cycle", [
            "nextRunAt": Date().addingTimeInterval(interval)
        ])
    }
    
    /// Stop automatic validation
    func stopAutoValidation() {
        validationTimer?.invalidate()
        validationTimer = nil
        eventBus.emit("autovalidation:stopped", [:])
    }
    
    /// Perform auto-validation
    private func performAutoValidation(licenseKey: String) async {
        do {
            try await validate(licenseKey: licenseKey)
        } catch {
            log("Auto-validation failed:", error)
            eventBus.emit("validation:auto-failed", [
                "licenseKey": licenseKey,
                "error": error
            ])
        }
        
        // Announce next scheduled run
        if validationTimer != nil {
            eventBus.emit("autovalidation:cycle", [
                "nextRunAt": Date().addingTimeInterval(config.autoValidateInterval)
            ])
        }
    }
}

// MARK: - Connectivity Polling

extension LicenseSeat {
    
    /// Start connectivity polling (fallback when Network framework unavailable)
    func startConnectivityPolling() {
        guard connectivityTimer == nil else { return }
        
        connectivityTimer = Timer.scheduledTimer(
            withTimeInterval: config.networkRecheckInterval,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor in
                await self?.checkConnectivity()
            }
        }
    }
    
    /// Stop connectivity polling
    func stopConnectivityPolling() {
        connectivityTimer?.invalidate()
        connectivityTimer = nil
    }
    
    /// Check connectivity by hitting heartbeat endpoint
    private func checkConnectivity() async {
        do {
            let _: EmptyResponse = try await apiClient.get(path: "/heartbeat")
            
            // Success - we're back online
            if !isOnline {
                handleNetworkStatusChange(isOnline: true)
            }
            stopConnectivityPolling()
        } catch {
            // Still offline
        }
    }
}

// MARK: - Offline Assets Sync

extension LicenseSeat {
    
    /// Sync offline license and public key
    func syncOfflineAssets() async {
        do {
            let offlineLicense = try await getOfflineLicense()
            cache.setOfflineLicense(offlineLicense)
            
            // Extract key ID
            let kid = offlineLicense.kid ?? offlineLicense.payload?["kid"] as? String
            if let kid = kid {
                // Check if we already have this key
                if cache.getPublicKey(kid) == nil {
                    let publicKey = try await getPublicKey(keyId: kid)
                    cache.setPublicKey(kid, publicKey)
                }
            }
            
            eventBus.emit("offlineLicense:ready", [
                "kid": kid as Any,
                "exp_at": offlineLicense.payload?["exp_at"] as Any
            ])
            
        } catch {
            log("Failed to sync offline assets:", error)
        }
    }
    
    /// Schedule periodic offline refresh
    func scheduleOfflineRefresh() {
        stopOfflineRefresh()
        
        offlineRefreshTimer = Timer.scheduledTimer(
            withTimeInterval: config.offlineLicenseRefreshInterval,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor in
                await self?.syncOfflineAssets()
            }
        }
    }
    
    /// Stop offline refresh timer
    func stopOfflineRefresh() {
        offlineRefreshTimer?.invalidate()
        offlineRefreshTimer = nil
    }
    
    /// Get offline license from server
    private func getOfflineLicense() async throws -> OfflineLicense {
        guard let license = cache.getLicense() else {
            let error = LicenseSeatError.noActiveLicense
            eventBus.emit("sdk:error", ["message": error.localizedDescription])
            throw error
        }
        
        eventBus.emit("offlineLicense:fetching", ["licenseKey": license.licenseKey])
        
        do {
            let response: OfflineLicense = try await apiClient.post(
                path: "/licenses/\(license.licenseKey)/offline_license"
            )
            
            eventBus.emit("offlineLicense:fetched", [
                "licenseKey": license.licenseKey,
                "data": response
            ])
            
            return response
            
        } catch {
            log("Failed to get offline license for \(license.licenseKey):", error)
            eventBus.emit("offlineLicense:fetchError", [
                "licenseKey": license.licenseKey,
                "error": error
            ])
            throw error
        }
    }
    
    /// Get public key from server
    internal func getPublicKey(keyId: String) async throws -> String {
        guard !keyId.isEmpty else {
            throw LicenseSeatError.invalidKeyId
        }
        
        log("Fetching public key for kid: \(keyId)")
        
        struct PublicKeyResponse: Codable {
            let keyId: String
            let publicKeyB64: String
            
            enum CodingKeys: String, CodingKey {
                case keyId = "key_id"
                case publicKeyB64 = "public_key_b64"
            }
        }
        
        let response: PublicKeyResponse = try await apiClient.get(
            path: "/public_keys/\(keyId)"
        )
        
        guard !response.publicKeyB64.isEmpty else {
            throw LicenseSeatError.invalidPublicKey
        }
        
        log("Successfully fetched public key for kid: \(keyId)")
        return response.publicKeyB64
    }
} 