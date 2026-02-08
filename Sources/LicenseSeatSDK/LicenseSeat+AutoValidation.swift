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
        // Cancel any existing timer/task
        stopAutoValidation()

        currentAutoLicenseKey = licenseKey
        let interval = config.autoValidateInterval

        // Don't start auto-validation if interval is 0 or negative
        guard interval > 0 else {
            log("Auto-validation disabled (interval: \(interval))")
            return
        }

        // Schedule validation using a detached Task so we are not tied to a RunLoop.
        validationTask = Task.detached { [weak self] in
            guard let self else { return }
            // Emit first cycle information immediately so the UI can show when the next run will be.
            await MainActor.run {
                self.eventBus.emit("autovalidation:cycle", [
                    "nextRunAt": Date().addingTimeInterval(interval)
                ])
            }

            // Continuous loop until cancelled.
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                } catch {
                    // Task was likely cancelled – exit loop
                    break
                }

                await MainActor.run {
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        await self.performAutoValidation(licenseKey: licenseKey)
                    }
                }
            }
        }
    }

    /// Stop automatic validation
    func stopAutoValidation() {
        // Invalidate legacy timer (if any)
        validationTimer?.invalidate()
        validationTimer = nil
        // Cancel concurrency task
        validationTask?.cancel()
        validationTask = nil
        eventBus.emit("autovalidation:stopped", [:])
    }

    /// Perform auto-validation
    private func performAutoValidation(licenseKey: String) async {
        do {
            _ = try await validate(licenseKey: licenseKey)
        } catch {
            log("Auto-validation failed:", error)
            eventBus.emit("validation:auto-failed", [
                "licenseKey": licenseKey,
                "error": error
            ])
        }

        Task { [weak self] in
            try? await self?.heartbeat()
        }

        // Announce next scheduled run
        if validationTask != nil {
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

    /// Check connectivity by hitting health endpoint
    private func checkConnectivity() async {
        do {
            // GET /health
            let _: HealthResponse = try await apiClient.get(path: "/health")

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

    /// Sync offline token and public key
    func syncOfflineAssets() async {
        do {
            let offlineToken = try await getOfflineToken()
            cache.setOfflineToken(offlineToken)

            // Extract key ID from token
            let kid = offlineToken.token.kid
            // Check if we already have this key
            if cache.getPublicKey(kid) == nil {
                let publicKey = try await getSigningKey(keyId: kid)
                cache.setPublicKey(kid, publicKey)
            }

            eventBus.emit("offlineToken:ready", [
                "kid": kid,
                "exp": offlineToken.token.exp
            ])

            // Immediately verify offline token locally so that
            // active entitlements (and other validation fields) are
            // cached and available even when we are online.
            if let offlineResult = await quickVerifyCachedOfflineLocal() {
                cache.updateValidation(offlineResult)
                if offlineResult.valid {
                    eventBus.emit("validation:offline-success", offlineResult)
                } else {
                    eventBus.emit("validation:offline-failed", offlineResult)
                }
            }

        } catch {
            log("Failed to sync offline assets:", error)
        }
    }

    /// Schedule periodic offline refresh
    func scheduleOfflineRefresh() {
        stopOfflineRefresh()

        offlineRefreshTimer = Timer.scheduledTimer(
            withTimeInterval: config.offlineTokenRefreshInterval,
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

    /// Get offline token from server
    private func getOfflineToken() async throws -> OfflineTokenResponse {
        guard let productSlug = config.productSlug else {
            throw LicenseSeatError.productSlugRequired
        }

        guard let license = cache.getLicense() else {
            let error = LicenseSeatError.noActiveLicense
            eventBus.emit("sdk:error", ["message": error.localizedDescription])
            throw error
        }

        eventBus.emit("offlineToken:fetching", ["licenseKey": license.licenseKey])

        do {
            var body: [String: Any] = [:]
            body["device_id"] = license.deviceId

            // POST /products/{slug}/licenses/{key}/offline-token
            let response: OfflineTokenResponse = try await apiClient.post(
                path: "/products/\(productSlug)/licenses/\(license.licenseKey)/offline-token",
                body: body
            )

            eventBus.emit("offlineToken:fetched", [
                "licenseKey": license.licenseKey
            ])

            return response

        } catch {
            log("Failed to get offline token for \(license.licenseKey):", error)
            eventBus.emit("offlineToken:fetchError", [
                "licenseKey": license.licenseKey,
                "error": error
            ])
            throw error
        }
    }

    /// Get signing key (public key) from server
    internal func getSigningKey(keyId: String) async throws -> String {
        guard !keyId.isEmpty else {
            throw LicenseSeatError.invalidKeyId
        }

        log("Fetching signing key for kid: \(keyId)")

        // GET /signing-keys/{key_id}
        let response: SigningKeyResponse = try await apiClient.get(
            path: "/signing-keys/\(keyId)"
        )

        guard !response.publicKey.isEmpty else {
            throw LicenseSeatError.invalidPublicKey
        }

        log("Successfully fetched signing key for kid: \(keyId)")
        return response.publicKey
    }
}
