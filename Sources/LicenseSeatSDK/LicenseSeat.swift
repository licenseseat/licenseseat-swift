//
//  LicenseSeat.swift
//  LicenseSeatSDK
//
//  Created by LicenseSeat on 2025.
//  Copyright © 2025 LicenseSeat. All rights reserved.
//

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Foundation
#if canImport(Combine)
import Combine
#endif
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif
#if canImport(Network)
import Network
#endif

/// The main entry point for the LicenseSeat SDK.
///
/// This class provides comprehensive license management functionality including:
/// - License activation and deactivation
/// - Online and offline validation
/// - Automatic re-validation
/// - Entitlement checking
/// - Event-driven architecture
/// - Device fingerprinting
/// - Network connectivity monitoring
///
/// ## Basic Usage
///
/// ```swift
/// // Initialize with configuration
/// let config = LicenseSeatConfig(
///     apiKey: "your-api-key",
///     productSlug: "my-app"
/// )
/// let licenseSeat = LicenseSeat(config: config)
///
/// // Activate a license
/// let license = try await licenseSeat.activate(licenseKey: "USER-KEY")
///
/// // Check status
/// let status = licenseSeat.getStatus()
/// ```
///
/// ## Event Handling
///
/// The SDK emits events throughout the license lifecycle:
///
/// ```swift
/// // Subscribe to events
/// let cancellable = licenseSeat.on("validation:success") { data in
///     print("License validated!")
/// }
///
/// // Using Combine
/// licenseSeat.statusPublisher
///     .sink { status in
///         updateUI(for: status)
///     }
///     .store(in: &cancellables)
/// ```
///
/// ## Thread Safety
///
/// All public methods are safe to call from any thread. UI updates from event handlers
/// and publishers should be dispatched to the main queue when necessary.
// MARK: - LicenseSeat Main Class
@MainActor
public final class LicenseSeat {

    // MARK: - Properties

    /// Canonical singleton instance used by the convenience static APIs.
    private static var _shared: LicenseSeat = LicenseSeat()

    /// Thread-safe accessor for the shared instance.
    public static var shared: LicenseSeat { _shared }

    /// Current configuration
    public let config: LicenseSeatConfig

    /// Cache manager for license persistence
    internal let cache: LicenseCache

    /// API client for network requests
    internal let apiClient: APIClient

    /// Event bus for SDK events
    internal let eventBus = EventBus()

    /// Network connectivity monitor
    #if canImport(Network)
    private var networkMonitor: NWPathMonitor?
    private let networkQueue = DispatchQueue(label: "com.licenseseat.sdk.network")
    #endif

    /// Timer for automatic validation
    internal var validationTimer: Timer?

    /// Concurrency task for automatic validation (run-loop independent)
    internal var validationTask: Task<Void, Never>?

    /// Concurrency task for standalone heartbeat pings
    internal var heartbeatTask: Task<Void, Never>?

    /// Timer for connectivity polling (fallback when NWPathMonitor unavailable)
    internal var connectivityTimer: Timer?

    /// Timer for offline token refresh
    internal var offlineRefreshTimer: Timer?

    /// Current auto-validation license key
    internal var currentAutoLicenseKey: String?

    /// Online/offline status
    public private(set) var isOnline = true

    /// Last offline validation result to avoid duplicate events
    private var lastOfflineValidation: ValidationResponse?

    // MARK: - Initialization

    /// Initialize with custom configuration
    /// - Parameter config: Configuration options
    /// - Parameter urlSession: URLSession for dependency injection
    public init(config: LicenseSeatConfig = .default, urlSession: URLSession? = nil) {
        self.config = config
        self.cache = LicenseCache(prefix: config.storagePrefix)
        self.apiClient = APIClient(config: config, session: urlSession)

        // Set up API client event forwarding
        apiClient.onNetworkStatusChange = { [weak self] isOnline in
            Task { @MainActor in
                self?.handleNetworkStatusChange(isOnline: isOnline)
            }
        }

        Task {
            await initialize()
        }
    }

    /// Initialize SDK components
    private func initialize() async {
        log("LicenseSeat SDK initialized", config)

        // Set up network monitoring
        setupNetworkMonitoring()

        // Check for cached license
        if let cachedLicense = cache.getLicense() {
            eventBus.emit("license:loaded", cachedLicense)

            // Quick offline verification for instant UX
            Task {
                if let offlineResult = await quickVerifyCachedOfflineLocal() {
                    cache.updateValidation(offlineResult)
                    if offlineResult.valid {
                        eventBus.emit("validation:offline-success", offlineResult)
                    } else {
                        eventBus.emit("validation:offline-failed", offlineResult)
                    }
                    lastOfflineValidation = offlineResult
                }
            }

            // Start auto-validation and heartbeat if API key is configured
            if config.apiKey != nil {
                startAutoValidation(licenseKey: cachedLicense.licenseKey)
                startHeartbeat(licenseKey: cachedLicense.licenseKey)

                // Background validation
                Task {
                    do {
                        try await validate(licenseKey: cachedLicense.licenseKey)
                    } catch {
                        log("Background validation failed:", error)

                        if let apiError = error as? APIError,
                           apiError.status == 401 || apiError.status == 501 {
                            log("Authentication issue during validation, using cached license data")
                            eventBus.emit("validation:auth-failed", [
                                "licenseKey": cachedLicense.licenseKey,
                                "error": error,
                                "cached": true
                            ])
                        }
                    }
                }
            }
        }
    }

    // MARK: - Public API

    /// Activate a license
    /// - Parameters:
    ///   - licenseKey: The license key to activate
    ///   - options: Additional activation options
    /// - Returns: The activated license
    /// - Throws: ``LicenseSeatError`` or ``APIError`` if activation fails
    public func activate(
        licenseKey: String,
        options: ActivationOptions = ActivationOptions()
    ) async throws -> License {
        guard let productSlug = config.productSlug else {
            throw LicenseSeatError.productSlugRequired
        }

        let deviceId = options.deviceId ?? config.deviceIdentifier ?? DeviceIdentifier.generate()

        var body: [String: Any] = [
            "device_id": deviceId
        ]

        if let deviceName = options.deviceName {
            body["device_name"] = deviceName
        }

        if let metadata = options.metadata {
            body["metadata"] = metadata
        }

        eventBus.emit("activation:start", ["licenseKey": licenseKey, "deviceId": deviceId])

        do {
            // POST /products/{slug}/licenses/{key}/activate
            let activation: ActivationResponse = try await apiClient.post(
                path: "/products/\(productSlug)/licenses/\(licenseKey)/activate",
                body: body
            )

            // Create and cache license
            let license = License(
                licenseKey: licenseKey,
                deviceId: deviceId,
                activationId: activation.id,
                activatedAt: activation.activatedAt,
                lastValidated: Date()
            )

            cache.setLicense(license)

            // Start auto-validation and heartbeat
            startAutoValidation(licenseKey: licenseKey)
            startHeartbeat(licenseKey: licenseKey)

            // Sync offline assets
            Task {
                await syncOfflineAssets()
            }
            scheduleOfflineRefresh()

            eventBus.emit("activation:success", license)
            return license

        } catch {
            eventBus.emit("activation:error", ["licenseKey": licenseKey, "error": error])
            throw error
        }
    }

    /// Validate a license
    /// - Parameters:
    ///   - licenseKey: License key to validate
    ///   - options: Validation options
    /// - Returns: Validation result
    /// - Throws: ``LicenseSeatError`` or ``APIError`` if validation cannot be completed
    public func validate(
        licenseKey: String,
        options: ValidationOptions = ValidationOptions()
    ) async throws -> ValidationResponse {
        guard let productSlug = config.productSlug else {
            throw LicenseSeatError.productSlugRequired
        }

        eventBus.emit("validation:start", ["licenseKey": licenseKey])

        do {
            let deviceId = options.deviceId ?? cache.getDeviceId()
            var body: [String: Any] = [:]

            if let deviceId = deviceId {
                body["device_id"] = deviceId
            }

            // POST /products/{slug}/licenses/{key}/validate
            let result: ValidationResponse = try await apiClient.post(
                path: "/products/\(productSlug)/licenses/\(licenseKey)/validate",
                body: body.isEmpty ? nil : body
            )

            // Update cache
            if let cachedLicense = cache.getLicense(),
               cachedLicense.licenseKey == licenseKey {
                cache.updateValidation(result)
            }

            if result.valid {
                eventBus.emit("validation:success", result)
                cache.setLastSeenTimestamp(Date().timeIntervalSince1970)
            } else {
                eventBus.emit("validation:failed", result)
                stopAutoValidation()
                currentAutoLicenseKey = nil
            }

            return result

        } catch {
            eventBus.emit("validation:error", ["licenseKey": licenseKey, "error": error])

            // Check for semantic failures from backend
            if let apiError = error as? APIError,
               (400...499).contains(apiError.status),
               apiError.status != 401, apiError.status != 429 {
                // Purge cached data - server is authoritative
                cache.clear()
                stopAutoValidation()
                currentAutoLicenseKey = nil
                lastOfflineValidation = nil

                eventBus.emit("license:revoked", [
                    "code": apiError.status,
                    "message": apiError.message
                ])

                throw error
            }

            // Try offline fallback for transport errors
            if shouldFallbackToOffline(error: error) {
                let offlineResult = await verifyCachedOffline()
                if let cachedLicense = cache.getLicense(),
                   cachedLicense.licenseKey == licenseKey {
                    cache.updateValidation(offlineResult)
                }

                if offlineResult.valid {
                    if lastOfflineValidation?.valid != true {
                        eventBus.emit("validation:offline-success", offlineResult)
                    }
                    lastOfflineValidation = offlineResult
                    return offlineResult
                } else {
                    eventBus.emit("validation:offline-failed", offlineResult)
                    stopAutoValidation()
                    currentAutoLicenseKey = nil
                }
            }

            throw error
        }
    }

    /// Deactivate the current license
    /// - Throws: ``LicenseSeatError/noActiveLicense`` if no license is active
    /// - Throws: ``APIError`` if server request fails
    public func deactivate() async throws {
        guard let productSlug = config.productSlug else {
            throw LicenseSeatError.productSlugRequired
        }

        guard let license = cache.getLicense() else {
            throw LicenseSeatError.noActiveLicense
        }

        eventBus.emit("deactivation:start", license)

        func completeLocalDeactivation() {
            cache.clearLicense()
            cache.clearOfflineToken()
            stopAutoValidation()
            stopHeartbeat()
            stopOfflineRefresh()
        }

        func shouldTreatAsSuccess(_ error: Error) -> Bool {
            guard let apiError = error as? APIError else { return false }
            switch apiError.status {
            case 404, 410:
                return true
            case 422:
                if let code = apiError.code {
                    return ["revoked", "already_deactivated", "not_active", "not_found", "suspended", "expired"].contains(code)
                }
                return false
            default:
                return false
            }
        }

        do {
            // POST /products/{slug}/licenses/{key}/deactivate
            let _: DeactivationResponse = try await apiClient.post(
                path: "/products/\(productSlug)/licenses/\(license.licenseKey)/deactivate",
                body: ["device_id": license.deviceId]
            )

            completeLocalDeactivation()
            eventBus.emit("deactivation:success", [:])
        } catch {
            if shouldTreatAsSuccess(error) {
                completeLocalDeactivation()
                eventBus.emit("deactivation:success", [:])
                return
            }
            eventBus.emit("deactivation:error", ["error": error, "license": license])
            throw error
        }
    }

    /// Send a heartbeat for the current license
    /// - Throws: ``LicenseSeatError/productSlugRequired`` if product slug is not configured
    public func heartbeat() async throws {
        guard let productSlug = config.productSlug else {
            throw LicenseSeatError.productSlugRequired
        }

        guard let license = cache.getLicense() else {
            log("No active license for heartbeat")
            return
        }

        let deviceId = license.deviceId

        let body: [String: Any] = ["device_id": deviceId]

        let _: HeartbeatResponse = try await apiClient.post(
            path: "/products/\(productSlug)/licenses/\(license.licenseKey)/heartbeat",
            body: body
        )

        eventBus.emit("heartbeat:success", [:])
        log("Heartbeat sent successfully")
    }

    /// Check if a specific entitlement is active
    /// - Parameter entitlementKey: The entitlement key to check
    /// - Returns: Entitlement status including active state and expiration
    public func checkEntitlement(_ entitlementKey: String) -> EntitlementStatus {
        guard let license = cache.getLicense(),
              let validation = license.validation else {
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
    public func getStatus() -> LicenseStatus {
        guard let license = cache.getLicense() else {
            return .inactive(message: "No license activated")
        }

        guard let validation = license.validation else {
            return .pending(message: "License pending validation")
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

        return .active(details: details)
    }

    /// Get the current cached license
    public func currentLicense() -> License? {
        cache.getLicense()
    }

    /// Check API health
    public func healthCheck() async throws -> HealthResponse {
        // GET /health
        try await apiClient.get(path: "/health")
    }

    /// Reset SDK state
    public func reset() {
        stopAutoValidation()
        stopHeartbeat()
        stopOfflineRefresh()
        cache.clear()
        lastOfflineValidation = nil
        eventBus.emit("sdk:reset", [:])
    }

    /// Purge any cached license and related offline assets.
    public func purgeCachedLicense() {
        cache.clear()
        stopAutoValidation()
        stopHeartbeat()
        stopOfflineRefresh()
        currentAutoLicenseKey = nil
        lastOfflineValidation = nil
        eventBus.emit("sdk:reset", [:])
    }

    // MARK: - Event Handling

    /// Subscribe to SDK events
    /// - Parameters:
    ///   - event: Event name
    ///   - handler: Event handler
    /// - Returns: Cancellable subscription
    @discardableResult
    public func on(_ event: String, handler: @escaping (Any) -> Void) -> AnyCancellable {
        eventBus.on(event, handler: handler)
    }

    // MARK: - Private Methods

    private func setupNetworkMonitoring() {
        #if canImport(Network)
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
        startConnectivityPolling()
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

        if let licenseKey = currentAutoLicenseKey, validationTimer == nil && validationTask == nil {
            startAutoValidation(licenseKey: licenseKey)
        }

        Task {
            await syncOfflineAssets()
        }
    }

    private func handleNetworkDisconnection() {
        eventBus.emit("network:offline", [:])
        stopAutoValidation()
        startConnectivityPolling()
    }

    private func shouldFallbackToOffline(error: Error) -> Bool {
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

    internal func log(_ items: Any...) {
        guard config.debug else { return }
        let message = items.map { "\($0)" }.joined(separator: " ")
        print("[LicenseSeat SDK]", message)
    }

    deinit {
        validationTimer?.invalidate()
        connectivityTimer?.invalidate()
        offlineRefreshTimer?.invalidate()
        validationTask?.cancel()
        heartbeatTask?.cancel()
        #if canImport(Network)
        networkMonitor?.cancel()
        #endif
    }
}

// MARK: - Supporting Types

/// Options for license activation
public struct ActivationOptions: Sendable {
    public var deviceId: String?
    public var deviceName: String?
    public var metadata: [String: Any]?

    public init(
        deviceId: String? = nil,
        deviceName: String? = nil,
        metadata: [String: Any]? = nil
    ) {
        self.deviceId = deviceId
        self.deviceName = deviceName
        self.metadata = metadata
    }
}

/// Options for license validation
public struct ValidationOptions: Sendable {
    public var deviceId: String?

    public init(deviceId: String? = nil) {
        self.deviceId = deviceId
    }
}

// MARK: - Global Lifecycle Helpers (Static Convenience)

public extension LicenseSeat {
    /// Creates (or recreates) the shared instance with a custom configuration.
    @MainActor
    static func configure(
        apiKey: String,
        productSlug: String,
        apiBaseURL: URL? = nil,
        force: Bool = false,
        options customize: (inout LicenseSeatConfig) -> Void = { _ in }
    ) {
        if _shared.config.apiKey != nil && !force { return }
        var cfg = LicenseSeatConfig.default
        cfg.apiKey = apiKey
        cfg.productSlug = productSlug
        if let apiBaseURL {
            cfg.apiBaseUrl = apiBaseURL.absoluteString
        }
        customize(&cfg)
        _shared = LicenseSeat(config: cfg)
    }

    /// Activate a license through the shared instance.
    @discardableResult
    static func activate(_ key: String, options: ActivationOptions = ActivationOptions()) async throws -> License {
        try await shared.activate(licenseKey: key, options: options)
    }

    /// Deactivate the current license through the shared instance.
    static func deactivate() async throws {
        try await shared.deactivate()
    }

    /// Check the status of a single entitlement.
    static func entitlement(_ id: String) -> EntitlementStatus {
        shared.checkEntitlement(id)
    }

    #if canImport(Combine)
    /// Publisher mirroring ``statusPublisher`` on the shared instance for quick subscriptions.
    static var statusPublisher: AnyPublisher<LicenseStatus, Never> {
        shared.statusPublisher
    }
    #endif
}
