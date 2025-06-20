//
//  LicenseSeat.swift
//  LicenseSeatSDK
//
//  Created by LicenseSeat on 2025.
//  Copyright © 2025 LicenseSeat. All rights reserved.
//

import Foundation
import Combine
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
@MainActor
public final class LicenseSeat: ObservableObject {
    
    // MARK: - Properties
    
    /// Shared singleton instance
    public static let shared = LicenseSeat()
    
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
            
            // Quick offline verification for instant UX
            if config.offlineFallbackEnabled {
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
            
            // Sync offline assets
            Task {
                await syncOfflineAssets()
            }
            
            // Schedule offline refresh
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
            
            let result: LicenseValidationResult = try await apiClient.post(
                path: "/licenses/validate",
                body: body
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
            
            // Check if we should fall back to offline
            if shouldFallbackToOffline(error: error) {
                let offlineResult = await verifyCachedOffline()
                
                // Update cache
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
            
            // Persist invalid status from API error
            if let apiError = error as? APIError,
               let data = apiError.data as? [String: Any],
               let cachedLicense = cache.getLicense(),
               cachedLicense.licenseKey == licenseKey {
                
                let invalidValidation = LicenseValidationResult(
                    valid: false,
                    reason: data["reason"] as? String,
                    offline: false
                )
                cache.updateValidation(invalidValidation)
                
                // Stop auto-validation for non-transient errors
                if ![0, 408, 429].contains(apiError.status) {
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
    ///
    /// Deactivates the current license on the server and clears all local data.
    /// After deactivation, the SDK returns to an inactive state.
    public func deactivate() async throws {
        guard let license = cache.getLicense() else {
            throw LicenseSeatError.noActiveLicense
        }
        
        eventBus.emit("deactivation:start", license)
        
        do {
            let _: EmptyResponse = try await apiClient.post(
                path: "/activations/deactivate",
                body: [
                    "license_key": license.licenseKey,
                    "device_identifier": license.deviceIdentifier
                ]
            )
            
            // Clear everything
            cache.clearLicense()
            cache.clearOfflineLicense()
            stopAutoValidation()
            stopOfflineRefresh()
            
            eventBus.emit("deactivation:success", EmptyResponse())
            
        } catch {
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
            Task { @MainActor in
                let wasOnline = self?.isOnline ?? true
                self?.isOnline = path.status == .satisfied
                
                if !wasOnline && self?.isOnline == true {
                    self?.handleNetworkReconnection()
                } else if wasOnline && self?.isOnline == false {
                    self?.handleNetworkDisconnection()
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
        
        if let licenseKey = currentAutoLicenseKey, validationTimer == nil {
            startAutoValidation(licenseKey: licenseKey)
        }
        
        Task {
            await syncOfflineAssets()
        }
    }
    
    private func handleNetworkDisconnection() {
        eventBus.emit("network:offline", [:])
        stopAutoValidation()
        #if !canImport(Network)
        startConnectivityPolling()
        #endif
    }
    
    private func shouldFallbackToOffline(error: Error) -> Bool {
        guard config.offlineFallbackEnabled else { return false }
        
        if error is URLError {
            return true
        }
        
        if let apiError = error as? APIError,
           [0, 408].contains(apiError.status) {
            return true
        }
        
        return false
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