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
///     apiBaseUrl: "https://api.licenseseat.com",
///     apiKey: "your-api-key"
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
public final class LicenseSeat: ObservableObject {
    
    // MARK: - Properties
    
    /// Canonical singleton instance used by the convenience static APIs.
    ///
    /// The instance can be re-created by calling ``configure(apiKey:apiBaseURL:options:)`` **before**
    /// any other call is made.  Subsequent calls to ``configure`` are ignored unless you pass
    /// `force: true` so background services and Combine subscriptions aren't accidentally reset.
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
    
    /// Timer for connectivity polling (fallback when NWPathMonitor unavailable)
    internal var connectivityTimer: Timer?
    
    /// Timer for offline license refresh
    internal var offlineRefreshTimer: Timer?
    
    /// Current auto-validation license key
    internal var currentAutoLicenseKey: String?
    
    /// Online/offline status
    @Published public private(set) var isOnline = true
    
    /// Last offline validation result to avoid duplicate events
    private var lastOfflineValidation: LicenseValidationResult?
    
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
            
            // Quick offline verification for instant UX.  This runs irrespective
            // of `offlineFallbackMode`: the local cryptographic check is cheap
            // and provides immediate status information even when we expect to
            // be online shortly after.
            do {
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
            }
            
            // Start auto-validation if API key is configured
            if config.apiKey != nil {
                startAutoValidation(licenseKey: cachedLicense.licenseKey)
                
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
    ///
    /// Activates a license key for the current device. This method:
    /// 1. Generates or uses a provided device identifier
    /// 2. Sends activation request to the server
    /// 3. Caches the activated license locally
    /// 4. Starts automatic validation timer
    /// 5. Syncs offline assets for resilience
    ///
    /// ## Example
    ///
    /// ```swift
    /// do {
    ///     let license = try await licenseSeat.activate(
    ///         licenseKey: "USER-LICENSE-KEY",
    ///         options: ActivationOptions(
    ///             deviceIdentifier: "custom-id",
    ///             metadata: ["version": "1.0.0"]
    ///         )
    ///     )
    ///     print("Activated: \(license.licenseKey)")
    /// } catch {
    ///     print("Activation failed: \(error)")
    /// }
    /// ```
    public func activate(
        licenseKey: String,
        options: ActivationOptions = ActivationOptions()
    ) async throws -> License {
        let deviceId = options.deviceIdentifier ?? config.deviceIdentifier ?? DeviceIdentifier.generate()
        
        var payload = ActivationPayload(
            licenseKey: licenseKey,
            deviceIdentifier: deviceId
        )
        
        payload.metadata = options.metadata
        payload.softwareReleaseDate = options.softwareReleaseDate
        
        eventBus.emit("activation:start", ["licenseKey": licenseKey, "deviceId": deviceId])
        
        do {
            let activation: ActivationResult = try await apiClient.post(
                path: "/activations/activate",
                body: payload
            )
            
            // Create and cache license
            let license = License(
                licenseKey: licenseKey,
                deviceIdentifier: deviceId,
                activation: activation,
                activatedAt: Date(),
                lastValidated: Date()
            )
            
            cache.setLicense(license)
            
            // Optimistic validation
            cache.updateValidation(LicenseValidationResult(
                valid: true,
                reason: nil,
                offline: false,
                optimistic: true
            ))
            
            // Start auto-validation
            startAutoValidation(licenseKey: licenseKey)
            
            // Sync offline assets & schedule refresh regardless of the selected
            // fallback strategy – the files are necessary for any kind of
            // offline validation.
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
    ///
    /// Validates a license against the server. If network is unavailable and offline
    /// fallback is enabled, attempts cryptographic offline validation.
    ///
    /// The validation result is automatically cached and the SDK's internal state updated.
    public func validate(
        licenseKey: String,
        options: ValidationOptions = ValidationOptions()
    ) async throws -> LicenseValidationResult {
        eventBus.emit("validation:start", ["licenseKey": licenseKey])
        
        do {
            let deviceId = options.deviceIdentifier ?? cache.getDeviceId() ?? ""
            var body: [String: Any] = [
                "license_key": licenseKey,
                "device_identifier": deviceId
            ]
            
            if let productSlug = options.productSlug {
                body["product_slug"] = productSlug
            }
            
            var result: LicenseValidationResult = try await apiClient.post(
                path: "/licenses/validate",
                body: body
            )
            
            // If the server response doesn't include entitlements, merge
            // any previously-cached list so we don't lose track after an
            // optimistic/offline cycle.
            if (result.activeEntitlements?.isEmpty ?? true),
               let cachedEnts = cache.getLicense()?.validation?.activeEntitlements,
               !cachedEnts.isEmpty {
                result = LicenseValidationResult(
                    valid: result.valid,
                    reason: result.reason,
                    offline: result.offline,
                    reasonCode: result.reasonCode,
                    optimistic: result.optimistic,
                    activeEntitlements: cachedEnts
                )
            }
            
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
            
            // First, inspect *semantic* failures coming from the backend to see
            // if we must invalidate the local cache immediately.
            if let apiError = error as? APIError,
               (400...499).contains(apiError.status),
               apiError.status != 401, apiError.status != 429 {
                // Purge any cached data – the server is authoritative.
                cache.clear()
                stopAutoValidation()
                currentAutoLicenseKey = nil
                lastOfflineValidation = nil

                let reason = (apiError.data as? [String: Any])?["reason"] as? String ?? apiError.message
                let invalidResult = LicenseValidationResult(valid: false, reason: reason, offline: false)
                eventBus.emit("validation:failed", invalidResult)
                eventBus.emit("license:revoked", [
                    "code": apiError.status,
                    "message": apiError.message
                ])

                // Surface invalid result to caller.
                return invalidResult
            }

            // For transport errors we may attempt an offline fallback.
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
                    return offlineResult
                }
            }

            // No fallback possible – bubble up.
            throw error
        }
    }
    
    /// Deactivate the current license
    /// - Throws: ``LicenseSeatError/noActiveLicense`` if no license is active
    /// - Throws: ``APIError`` if server request fails
    ///
    /// Deactivates the current license on the server and clears all local data.
    /// After deactivation, the SDK returns to an inactive state.
    public func deactivate() async throws {
        guard let license = cache.getLicense() else {
            throw LicenseSeatError.noActiveLicense
        }
        
        eventBus.emit("deactivation:start", license)
        
        // Helper that performs the local teardown that always accompanies a successful
        // (or pragmatically successful) deactivation.
        func completeLocalDeactivation() {
            cache.clearLicense()
            cache.clearOfflineLicense()
            stopAutoValidation()
            stopOfflineRefresh()
        }
        
        // Determines whether a particular API error should be treated as a *successful*
        // deactivation because the server no longer considers the activation valid.
        func shouldTreatAsSuccess(_ error: Error) -> Bool {
            guard let apiError = error as? APIError else { return false }
            switch apiError.status {
            case 404, 410:
                // License or activation not found / already gone.
                return true
            case 422:
                // Unprocessable – often means license revoked or already disabled.
                if let data = apiError.data as? [String: Any],
                   let code = data["code"] as? String {
                    return ["revoked", "already_deactivated", "not_active", "not_found", "suspended", "expired"].contains(code)
                }
                // Fallback to string heuristics on the message – keeps us resilient to
                // minor backend wording changes without depending on undocumented keys.
                let msg = apiError.message.lowercased()
                return msg.contains("revoked") || msg.contains("not found") || msg.contains("already") || msg.contains("suspended") || msg.contains("expired")
            default:
                return false
            }
        }
        
        do {
            let _: EmptyResponse = try await apiClient.post(
                path: "/activations/deactivate",
                body: [
                    "license_key": license.licenseKey,
                    "device_identifier": license.deviceIdentifier
                ]
            )
            // Server acknowledged deactivation – clear state.
            completeLocalDeactivation()
            eventBus.emit("deactivation:success", EmptyResponse())
        } catch {
            if shouldTreatAsSuccess(error) {
                // The server says the activation no longer exists / is invalid, so from the
                // client's perspective we are also deactivated. Treat it as success.
                completeLocalDeactivation()
                eventBus.emit("deactivation:success", EmptyResponse())
                return
            }
            // Genuine failure – bubble up.
            eventBus.emit("deactivation:error", ["error": error, "license": license])
            throw error
        }
    }
    
    /// Check if a specific entitlement is active
    /// - Parameter entitlementKey: The entitlement key to check
    /// - Returns: Entitlement status including active state and expiration
    ///
    /// Checks whether the current license includes a specific entitlement.
    /// This method works offline using cached validation data.
    ///
    /// ## Example
    ///
    /// ```swift
    /// let status = licenseSeat.checkEntitlement("premium-features")
    /// if status.active {
    ///     enablePremiumFeatures()
    /// } else if status.reason == .expired {
    ///     showRenewalPrompt()
    /// }
    /// ```
    public func checkEntitlement(_ entitlementKey: String) -> EntitlementStatus {
        guard let license = cache.getLicense(),
              let validation = license.validation else {
            return EntitlementStatus(active: false, reason: .noLicense, expiresAt: nil, entitlement: nil)
        }
        
        let entitlements = validation.activeEntitlements ?? []
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
    ///
    /// Returns the current license status based on cached data. This method
    /// never makes network requests and provides instant results.
    ///
    /// ## Status Types
    ///
    /// - ``LicenseStatus/active``: License is valid (online validated)
    /// - ``LicenseStatus/offlineValid``: License is valid (offline validated)
    /// - ``LicenseStatus/inactive``: No license activated
    /// - ``LicenseStatus/invalid``: License validation failed
    /// - ``LicenseStatus/pending``: Validation in progress
    public func getStatus() -> LicenseStatus {
        guard let license = cache.getLicense() else {
            return .inactive(message: "No license activated")
        }
        
        guard let validation = license.validation else {
            return .pending(message: "License pending validation")
        }
        
        if !validation.valid {
            if validation.offline {
                return .offlineInvalid(
                    message: validation.reasonCode ?? "License invalid (offline)"
                )
            }
            return .invalid(message: validation.reason ?? "License invalid")
        }
        
        let details = LicenseStatusDetails(
            license: license.licenseKey,
            device: license.deviceIdentifier,
            activatedAt: license.activatedAt,
            lastValidated: license.lastValidated,
            entitlements: validation.activeEntitlements ?? []
        )
        
        if validation.offline {
            return .offlineValid(details: details)
        }
        
        return .active(details: details)
    }
    
    /// Get the current cached license
    public func currentLicense() -> License? {
        cache.getLicense()
    }
    
    /// Test authentication
    public func testAuth() async throws -> AuthTestResponse {
        guard config.apiKey != nil else {
            let error = LicenseSeatError.apiKeyRequired
            eventBus.emit("auth_test:error", ["error": error])
            throw error
        }
        
        eventBus.emit("auth_test:start", [:])
        
        do {
            let response: AuthTestResponse = try await apiClient.get(path: "/auth_test")
            eventBus.emit("auth_test:success", response)
            return response
        } catch {
            eventBus.emit("auth_test:error", ["error": error])
            throw error
        }
    }
    
    /// Reset SDK state
    public func reset() {
        stopAutoValidation()
        stopOfflineRefresh()
        cache.clear()
        lastOfflineValidation = nil
        eventBus.emit("sdk:reset", [:])
    }
    
    /// Purge any cached license and related offline assets.
    ///
    /// Useful when you want to force the SDK back to an unauthenticated state
    /// without hitting the backend (e.g. after detecting an account logout
    /// event or when responding to a *license:revoked* notification).
    public func purgeCachedLicense() {
        cache.clear()
        stopAutoValidation()
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
    
    /// Unsubscribe from an event
    /// - Parameters:
    ///   - event: Event name
    ///   - handler: Handler to remove
    public func off(_ event: String, handler: @escaping (Any) -> Void) {
        eventBus.off(event, handler: handler)
    }
    
    // MARK: - Private Methods
    
    private func setupNetworkMonitoring() {
        #if canImport(Network)
        networkMonitor = NWPathMonitor()
        networkMonitor?.pathUpdateHandler = { [weak self] path in
            // Hop onto the main actor to update state and emit events safely.
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
        // Fallback to polling
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
        // Start heartbeat polling to detect server availability even when Network framework says we're online.
        startConnectivityPolling()
    }
    
    private func shouldFallbackToOffline(error: Error) -> Bool {
        switch config.offlineFallbackMode {
        case .always:
            return true
        case .networkOnly:
            // Transport-level issues
            if error is URLError { return true }
            if let apiError = error as? APIError {
                // `0` is often used by the API layer when the request never
                // reached the server (e.g. DNS failure / no connection).
                if apiError.status == 0 { return true }
                // 408 Request Timeout also indicates network/transient
                if apiError.status == 408 { return true }
                // 5xx → server-side fault
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
        #if canImport(Network)
        networkMonitor?.cancel()
        #endif
    }
}

// MARK: - Supporting Types

/// Options for license activation
public struct ActivationOptions {
    public var deviceIdentifier: String?
    public var softwareReleaseDate: String?
    public var metadata: [String: Any]?
    
    public init(
        deviceIdentifier: String? = nil,
        softwareReleaseDate: String? = nil,
        metadata: [String: Any]? = nil
    ) {
        self.deviceIdentifier = deviceIdentifier
        self.softwareReleaseDate = softwareReleaseDate
        self.metadata = metadata
    }
}

/// Options for license validation
public struct ValidationOptions {
    public var deviceIdentifier: String?
    public var productSlug: String?
    
    public init(
        deviceIdentifier: String? = nil,
        productSlug: String? = nil
    ) {
        self.deviceIdentifier = deviceIdentifier
        self.productSlug = productSlug
    }
}

// Empty response for deactivation
struct EmptyResponse: Codable {}

/// Auth test response
public struct AuthTestResponse: Codable {
    public let success: Bool
    public let message: String?
}

// MARK: - Global Lifecycle Helpers (Static Convenience)

public extension LicenseSeat {
    /// Creates (or recreates) the shared instance with a custom configuration.
    /// Calling this early at application start-up gives you a one-liner setup that mirrors popular
    /// libraries such as `SentrySDK.start(...)` or `Amplitude(configuration:)`.
    /// - Parameters:
    ///   - apiKey:       Your LicenseSeat API key.
    ///   - apiBaseURL:   Base URL for the LicenseSeat backend. Defaults to production.
    ///   - force:        Recreate the singleton even if it was already configured.
    ///   - customize:    Optional closure to tweak the default ``LicenseSeatConfig``.
    @MainActor
    static func configure(apiKey: String,
                          apiBaseURL: URL = URL(string: "https://api.licenseseat.com")!,
                          force: Bool = false,
                          options customize: (inout LicenseSeatConfig) -> Void = { _ in }) {
        if _shared.config.apiKey != nil && !force { return }
        var cfg = LicenseSeatConfig.default
        cfg.apiKey = apiKey
        cfg.apiBaseUrl = apiBaseURL.absoluteString
        customize(&cfg)
        _shared = LicenseSeat(config: cfg)
    }

    /// Activate a license through the shared instance.
    @discardableResult
    static func activate(_ key: String,
                         options: ActivationOptions = ActivationOptions()) async throws -> License {
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

    /// Publisher mirroring ``statusPublisher`` on the shared instance for quick subscriptions.
    static var statusPublisher: AnyPublisher<LicenseStatus, Never> {
        shared.statusPublisher
    }
} 