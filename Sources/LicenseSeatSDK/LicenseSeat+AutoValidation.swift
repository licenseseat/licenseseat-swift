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
        guard validScheduledInterval(interval) else {
            log("Auto-validation disabled (interval: \(interval))")
            return
        }

        // Schedule validation using a detached Task so we are not tied to a RunLoop.
        validationTask = Task.detached { [weak self] in
            // Emit first cycle information immediately so the UI can show when the next run will be.
            if let initialSelf = self {
                await MainActor.run {
                    initialSelf.eventBus.emit("autovalidation:cycle", [
                        "nextRunAt": Date().addingTimeInterval(interval)
                    ])
                }
            } else {
                return
            }

            // Continuous loop until cancelled.
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                } catch {
                    // Task was likely cancelled – exit loop
                    break
                }

                guard let strongSelf = self else { break }
                await strongSelf.performAutoValidation(licenseKey: licenseKey)
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

    // MARK: - Standalone Heartbeat

    /// Start a standalone heartbeat timer, independent from auto-validation.
    /// - Parameter licenseKey: The active license key (used for logging)
    func startHeartbeat(licenseKey: String) {
        stopHeartbeat()

        let interval = config.heartbeatInterval
        guard validScheduledInterval(interval) else {
            log("Standalone heartbeat disabled (interval: \(interval))")
            return
        }

        heartbeatTask = Task.detached { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                } catch {
                    break
                }

                guard let strongSelf = self else { break }
                do {
                    try await strongSelf.heartbeat()
                } catch {
                    await strongSelf.log("Standalone heartbeat failed (\(String(describing: type(of: error))))")
                }
            }
        }
    }

    /// Stop the standalone heartbeat timer
    func stopHeartbeat() {
        heartbeatTask?.cancel()
        heartbeatTask = nil
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

    private func validScheduledInterval(_ interval: TimeInterval) -> Bool {
        interval.isFinite && interval > 0 && interval <= 366 * 86_400
    }
}

// MARK: - Connectivity Polling

extension LicenseSeat {

    /// Start connectivity polling (fallback when Network framework unavailable)
    func startConnectivityPolling() {
        guard connectivityTimer == nil else { return }
        guard config.networkRecheckInterval.isFinite,
              config.networkRecheckInterval >= 0.1,
              config.networkRecheckInterval <= 86_400 else {
            log("Connectivity polling disabled due to invalid interval")
            return
        }

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

    /// Sync offline token and public key from the server.
    /// Downloads the offline token and its corresponding public signing key, caching both locally.
    /// Emits `offlineToken:ready` on success or `offlineToken:fetchError` on failure.
    public func syncOfflineAssets() async {
        guard (1...36_600).contains(config.maxOfflineDays) else {
            stopOfflineRefresh()
            return
        }
        do {
            let offlineToken = try await getOfflineToken()

            // Extract key ID from token
            let kid = offlineToken.token.kid
            // Refresh and verify the key before persisting any newly received
            // offline authority. A stale or locally poisoned cached key must
            // not make sync permanently unusable.
            let publicKey = try await getSigningKey(keyId: kid)
            let offlineResult = await evaluateOfflineToken(offlineToken, publicKeyB64: publicKey)
            guard offlineResult.valid else {
                throw LicenseSeatError.invalidOfflineToken
            }
            cache.setPublicKey(kid, publicKey)
            cache.setOfflineToken(offlineToken)
            cache.updateValidation(offlineResult, markValidatedOnline: false)

            eventBus.emit("offlineToken:ready", [
                "kid": kid,
                "exp": offlineToken.token.exp
            ])

            eventBus.emit("validation:offline-success", offlineResult)

        } catch {
            log("Failed to sync offline assets:", error)
        }
    }

    /// Schedule periodic offline refresh
    func scheduleOfflineRefresh() {
        stopOfflineRefresh()

        guard (1...36_600).contains(config.maxOfflineDays),
              config.offlineTokenRefreshInterval.isFinite,
              config.offlineTokenRefreshInterval >= 1,
              config.offlineTokenRefreshInterval <= 366 * 86_400 else {
            log("Offline refresh disabled due to invalid interval")
            return
        }

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
        try validateRequestIdentity(productSlug: productSlug, licenseKey: license.licenseKey)

        eventBus.emit("offlineToken:fetching", ["licenseKey": license.licenseKey])

        do {
            var body: [String: Any] = ["license_key": license.licenseKey]
            body["device_id"] = license.deviceId

            let response: OfflineTokenResponse = try await apiClient.post(
                path: "/products/\(productSlug)/licenses/offline-token",
                body: body
            )

            eventBus.emit("offlineToken:fetched", [
                "licenseKey": license.licenseKey
            ])

            return response

        } catch {
            log("Failed to get offline token (\(String(describing: type(of: error))))")
            eventBus.emit("offlineToken:fetchError", [
                "licenseKey": license.licenseKey,
                "error": error
            ])
            throw error
        }
    }

    /// Get signing key (public key) from server
    internal func getSigningKey(keyId: String) async throws -> String {
        guard keyId.utf8.count <= 255,
              keyId.range(of: "^[A-Za-z0-9][A-Za-z0-9._:-]*$", options: .regularExpression) != nil else {
            throw LicenseSeatError.invalidKeyId
        }

        log("Fetching signing key for kid: \(keyId)")

        // GET /signing_keys/{key_id}
        let response: SigningKeyResponse = try await apiClient.get(
            path: "/signing_keys/\(keyId)"
        )

        guard response.object == "signing_key",
              response.keyId == keyId,
              response.algorithm == "Ed25519",
              response.status == "active",
              let keyData = try? Base64URL.decode(response.publicKey),
              keyData.count == 32 else {
            throw LicenseSeatError.invalidPublicKey
        }

        log("Successfully fetched signing key for kid: \(keyId)")
        return response.publicKey
    }
}
