//
//  LicenseSeat+State.swift
//  LicenseSeatSDK
//
//  Cached state, entitlement, health, reset, and event APIs.
//

import Foundation
#if canImport(Combine)
import Combine
#endif

public extension LicenseSeat {
    /// Check if a specific entitlement is active
    /// - Parameter entitlementKey: The entitlement key to check
    /// - Returns: Entitlement status including active state and expiration
    func checkEntitlement(_ entitlementKey: String) -> EntitlementStatus {
        guard let license = cache.getLicense() else {
            return EntitlementStatus(active: false, reason: .noLicense, expiresAt: nil, entitlement: nil)
        }
        if lastOfflineValidation?.valid == false,
           lastOfflineValidation?.license.key == license.licenseKey {
            return EntitlementStatus(active: false, reason: .noLicense, expiresAt: nil, entitlement: nil)
        }
        guard
              let validation = license.validation,
              validation.valid else {
            return EntitlementStatus(active: false, reason: .noLicense, expiresAt: nil, entitlement: nil)
        }

        let entitlements = validation.license.activeEntitlements
        guard let entitlement = entitlements.first(where: { $0.key == entitlementKey }) else {
            return EntitlementStatus(active: false, reason: .notFound, expiresAt: nil, entitlement: nil)
        }

        if let expiresAt = entitlement.expiresAt {
            if expiresAt < Date() {
                return EntitlementStatus(
                    active: false,
                    reason: .expired,
                    expiresAt: expiresAt,
                    entitlement: entitlement
                )
            }
        }

        return EntitlementStatus(active: true, reason: nil, expiresAt: entitlement.expiresAt, entitlement: entitlement)
    }

    /// Get current license status
    /// - Returns: Current status of the license
    func getStatus() -> LicenseStatus {
        guard let license = cache.getLicense() else {
            return .inactive(message: "No license activated")
        }

        guard let validation = license.validation else {
            return .pending(message: "License pending validation")
        }

        if lastOfflineValidation?.valid == false,
           lastOfflineValidation?.license.key == license.licenseKey {
            let message = lastOfflineValidation?.message
                ?? lastOfflineValidation?.code
                ?? "Offline license invalid"
            return .offlineInvalid(message: message)
        }

        if !validation.valid {
            let message = validation.message ?? validation.code ?? "License invalid"
            return .invalid(message: message)
        }

        let details = LicenseStatusDetails(
            license: license.licenseKey,
            device: license.deviceId,
            activatedAt: license.activatedAt,
            lastValidated: license.lastValidated,
            entitlements: validation.license.activeEntitlements
        )

        if lastOfflineValidation?.valid == true,
           lastOfflineValidation?.license.key == validation.license.key {
            return .offlineValid(details: details)
        }

        return .active(details: details)
    }

    /// Get the current cached license
    func currentLicense() -> License? {
        cache.getLicense()
    }

    /// Check API health
    func healthCheck() async throws -> HealthResponse {
        await waitForInitialization()
        // GET /health
        return try await apiClient.get(path: "/health")
    }

    /// Reset SDK state
    func reset() {
        currentActivationRequestID = nil
        currentValidationRequestID = nil
        currentHeartbeatRequestID = nil
        currentOfflineSyncRequestID = nil
        initializationTask?.cancel()
        initializationTask = nil
        cancelBackgroundLicenseOperations()
        stopAutoValidation()
        stopHeartbeat()
        stopOfflineRefresh()
        stopConnectivityPolling()
        cache.clear()
        currentAutoLicenseKey = nil
        lastOfflineValidation = nil
        isOnline = true
        apiClient.resetNetworkStatus()
        setupNetworkMonitoring()
        eventBus.emit("sdk:reset", [:])
    }

    /// Purge any cached license and related offline assets.
    func purgeCachedLicense() {
        reset()
    }

    // MARK: - Event Handling

    /// Subscribe to SDK events
    /// - Parameters:
    ///   - event: Event name
    ///   - handler: Event handler
    /// - Returns: Cancellable subscription
    @discardableResult
    func on(_ event: String, handler: @escaping (Any) -> Void) -> AnyCancellable {
        eventBus.on(event, handler: handler)
    }
}
