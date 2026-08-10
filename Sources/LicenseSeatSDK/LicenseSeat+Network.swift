//
//  LicenseSeat+Network.swift
//  LicenseSeatSDK
//
//  Connectivity monitoring and offline-fallback policy.
//

import Foundation
#if canImport(Network)
import Network
#endif

extension LicenseSeat {
    internal func setupNetworkMonitoring() {
        #if canImport(Network)
        guard networkMonitor == nil else { return }
        networkMonitor = NWPathMonitor()
        networkMonitor?.pathUpdateHandler = { [weak self] path in
            Task { @MainActor [weak self] in
                guard let self else { return }

                let wasOnline = self.isOnline
                self.isOnline = path.status == .satisfied

                if !wasOnline && self.isOnline {
                    self.handleNetworkReconnection()
                } else if wasOnline && !self.isOnline {
                    self.handleNetworkDisconnection()
                }
            }
        }
        networkMonitor?.start(queue: networkQueue)
        #else
        // APIClient reports the first observed transport failure through
        // `handleNetworkStatusChange`. Only then should platforms without the
        // Network framework begin polling. Starting a repeating timer while the
        // client is presumed online wastes requests and keeps command-line
        // processes (including Linux XCTest) alive after their work is done.
        #endif
    }

    internal func handleNetworkStatusChange(isOnline: Bool) {
        let wasOnline = self.isOnline
        self.isOnline = isOnline

        if !wasOnline && isOnline {
            handleNetworkReconnection()
        } else if wasOnline && !isOnline {
            handleNetworkDisconnection()
        }
    }

    private func handleNetworkReconnection() {
        eventBus.emit("network:online", [:])
        stopConnectivityPolling()

        if let licenseKey = currentAutoLicenseKey {
            if validationTimer == nil && validationTask == nil {
                startAutoValidation(licenseKey: licenseKey)
            }
            if heartbeatTask == nil { startHeartbeat() }
            if config.offlineAuthorityEnabled {
                scheduleOfflineRefresh()
                startOfflineAssetSync()
            }
        }
    }

    private func handleNetworkDisconnection() {
        eventBus.emit("network:offline", [:])
        stopAutoValidation()
        stopHeartbeat()
        stopOfflineRefresh()
        startConnectivityPolling()
    }

    internal func shouldFallbackToOffline(error: Error) -> Bool {
        guard config.offlineAuthorityEnabled else { return false }
        switch config.offlineFallbackMode {
        case .always:
            return true
        case .networkOnly:
            if error is URLError { return true }
            if let apiError = error as? APIError {
                if apiError.status == 0 { return true }
                if apiError.status == 408 { return true }
                if (500...599).contains(apiError.status) { return true }
            }
            return false
        }
    }
}
