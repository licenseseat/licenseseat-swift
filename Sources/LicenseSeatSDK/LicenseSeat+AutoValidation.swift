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
        guard interval.isFinite, interval > 0,
              interval <= Double(UInt64.max) / 1_000_000_000 else {
            log("Auto-validation disabled (interval: \(interval))")
            return
        }

        // A Task is run-loop independent and inherits this type's MainActor.
        validationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            // Emit first cycle information immediately so the UI can show when the next run will be.
            self.eventBus.emit("autovalidation:cycle", [
                "nextRunAt": Date().addingTimeInterval(interval)
            ])

            // Continuous loop until cancelled.
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                } catch {
                    // Task was likely cancelled – exit loop
                    break
                }

                let operation = Task { @MainActor [weak self] in
                    await self?.performAutoValidation(licenseKey: licenseKey)
                }
                await operation.value
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
    func startHeartbeat() {
        stopHeartbeat()

        let interval = config.heartbeatInterval
        guard interval.isFinite, interval > 0,
              interval <= Double(UInt64.max) / 1_000_000_000 else {
            log("Standalone heartbeat disabled (interval: \(interval))")
            return
        }

        heartbeatTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                } catch {
                    break
                }

                let operation = Task { @MainActor [weak self] in
                    guard let self else { return }
                    do {
                        try await self.heartbeat()
                    } catch {
                        self.log("Standalone heartbeat failed:", error)
                    }
                }
                await operation.value
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

        let interval = config.networkRecheckInterval
        guard interval.isFinite, interval > 0 else {
            log("Connectivity polling disabled (interval: \(interval))")
            return
        }

        connectivityTimer = Timer.scheduledTimer(
            withTimeInterval: interval,
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

    /// Start a single tracked offline synchronization. Repeated triggers
    /// replace older work so a stale response cannot win a cache race.
    func startOfflineAssetSync() {
        offlineSyncTask?.cancel()
        offlineSyncTask = Task { @MainActor [weak self] in
            let operation = Task { @MainActor [weak self] in
                await self?.syncOfflineAssets()
            }
            await operation.value
        }
    }

    /// Sync offline token and public key from the server.
    /// Downloads the offline token and its corresponding public signing key, caching both locally.
    /// Emits `offlineToken:ready` on success or `offlineToken:fetchError` on failure.
    public func syncOfflineAssets() async {
        let requestID = UUID()
        currentOfflineSyncRequestID = requestID
        defer {
            if currentOfflineSyncRequestID == requestID {
                currentOfflineSyncRequestID = nil
            }
        }

        await waitForInitialization()
        guard currentOfflineSyncRequestID == requestID else { return }

        // Keep the identity associated with this request stable. A late
        // response from one activation must never overwrite or revoke its
        // replacement, even when the key and fingerprint are unchanged.
        guard let requestedLicense = cache.getLicense() else {
            let error = LicenseSeatError.noActiveLicense
            eventBus.emit("sdk:error", ["message": error.localizedDescription])
            eventBus.emit("offlineToken:fetchError", ["error": error])
            return
        }
        let requestedIdentity = CachedLicenseIdentity(requestedLicense)

        do {
            let offlineToken = try await getOfflineToken(for: requestedLicense)
            let kid = offlineToken.token.kid
            let verification = try await verifyOfflineTokenWithSigningKeyRecovery(offlineToken)
            try ensureCurrentOfflineSync(requestID, identity: requestedIdentity)
            try verifyDownloadedOfflineToken(verification.result)
            try ensureCurrentOfflineSync(requestID, identity: requestedIdentity)
            try persistOfflineAssets(offlineToken, publicKey: verification.publicKey)
            eventBus.emit("offlineToken:ready", [
                "kid": kid,
                "exp": offlineToken.token.exp
            ])

        } catch {
            guard currentOfflineSyncRequestID == requestID else { return }
            if let apiError = error as? APIError,
               apiError.invalidatesCachedLicense {
                handleAuthoritativeInvalidation(apiError, expectedIdentity: requestedIdentity)
            }
            log("Failed to sync offline assets:", error)
            eventBus.emit("offlineToken:fetchError", [
                "licenseKey": requestedLicense.licenseKey,
                "error": error
            ])
        }
    }

    private func ensureCurrentOfflineSync(
        _ requestID: UUID,
        identity: CachedLicenseIdentity
    ) throws {
        try Task.checkCancellation()
        guard currentOfflineSyncRequestID == requestID,
              cachedLicenseMatches(identity) else {
            throw CancellationError()
        }
    }

    private func verifyDownloadedOfflineToken(_ result: ValidationResponse) throws {
        // Verify a downloaded grant before it can replace the previous cache.
        // Malformed or mismatched responses therefore cannot poison working
        // offline recovery.
        guard result.valid else {
            throw LicenseSeatError.validationFailed(
                reason: result.code ?? "Offline token verification failed."
            )
        }
    }

    private func persistOfflineAssets(
        _ offlineToken: OfflineTokenResponse,
        publicKey: String
    ) throws {
        guard cache.setPublicKey(offlineToken.token.kid, publicKey),
              cache.setOfflineToken(offlineToken) else {
            throw LicenseSeatError.cacheError
        }
    }

    /// Schedule periodic offline refresh
    func scheduleOfflineRefresh() {
        stopOfflineRefresh()

        let interval = config.offlineTokenRefreshInterval
        guard interval.isFinite, interval > 0 else {
            log("Offline token refresh disabled (interval: \(interval))")
            return
        }

        offlineRefreshTimer = Timer.scheduledTimer(
            withTimeInterval: interval,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor in
                self?.startOfflineAssetSync()
            }
        }
    }

    /// Stop offline refresh timer
    func stopOfflineRefresh() {
        offlineRefreshTimer?.invalidate()
        offlineRefreshTimer = nil
    }

    /// Get offline token from server
    private func getOfflineToken(for license: License) async throws -> OfflineTokenResponse {
        guard let productSlug = config.productSlug else {
            throw LicenseSeatError.productSlugRequired
        }

        eventBus.emit("offlineToken:fetching", ["licenseKey": license.licenseKey])
        let response: OfflineTokenResponse = try await apiClient.post(
            pathComponents: [
                "products", productSlug, "licenses", license.licenseKey, "offline_token"
            ],
            body: ["fingerprint": license.deviceId]
        )
        eventBus.emit("offlineToken:fetched", ["licenseKey": license.licenseKey])
        return response
    }

    /// Get signing key (public key) from server
    internal func getSigningKey(keyId: String) async throws -> String {
        guard !keyId.isEmpty else {
            throw LicenseSeatError.invalidKeyId
        }

        log("Fetching signing key for kid: \(keyId)")

        // GET /signing_keys/{key_id}
        let response: SigningKeyResponse = try await apiClient.get(
            pathComponents: ["signing_keys", keyId]
        )

        guard response.object == "signing_key",
              response.keyId == keyId,
              response.algorithm.caseInsensitiveCompare("Ed25519") == .orderedSame,
              response.status.caseInsensitiveCompare("active") == .orderedSame,
              isValidEd25519PublicKey(response.publicKey) else {
            throw LicenseSeatError.invalidPublicKey
        }

        log("Successfully fetched signing key for kid: \(keyId)")
        return response.publicKey
    }

    internal func isValidEd25519PublicKey(_ publicKey: String) -> Bool {
        guard let bytes = try? Base64URL.decode(publicKey) else { return false }
        return bytes.count == 32
    }
}
