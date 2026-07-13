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
#if canImport(Network)
import Network
#endif

// MARK: - LicenseSeat Main Class

/// The main entry point for the LicenseSeat SDK.
///
/// This class provides comprehensive license management functionality including:
/// - License activation and deactivation
/// - Online and offline validation
/// - Automatic re-validation
/// - Entitlement checking
/// - Event-driven architecture
/// - App-scoped installation identity for seat binding
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
/// The SDK is isolated to the main actor. Calls made from background work should
/// cross to `MainActor`; event handlers and Combine publishers are delivered on
/// the main queue.
@MainActor
public final class LicenseSeat {

    /// Stable identity for correlating an asynchronous response with the exact
    /// cached activation that initiated it. A license key alone is insufficient:
    /// the same key can be reactivated on another device or receive a new
    /// activation ID while an older request is still in flight.
    internal struct CachedLicenseIdentity: Equatable, Sendable {
        let licenseKey: String
        let deviceId: String
        let activationId: String

        init(_ license: License) {
            licenseKey = license.licenseKey
            deviceId = license.deviceId
            activationId = license.activationId
        }

        static func == (lhs: CachedLicenseIdentity, rhs: CachedLicenseIdentity) -> Bool {
            lhs.licenseKey == rhs.licenseKey &&
                lhs.deviceId == rhs.deviceId &&
                lhs.activationId == rhs.activationId
        }
    }

    // MARK: - Properties

    /// Canonical singleton instance used by the convenience static APIs.
    internal static var _shared: LicenseSeat = LicenseSeat()

    /// Thread-safe accessor for the shared instance.
    public static var shared: LicenseSeat { _shared }

    /// Replaces the process-wide instance without creating a second singleton
    /// path. `LicenseSeatStore.shared` uses this hook so the static, Combine,
    /// and SwiftUI APIs always observe the same SDK state.
    internal static func installShared(_ instance: LicenseSeat) {
        guard _shared !== instance else { return }
        _shared.shutdown()
        _shared = instance
    }

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
    internal var networkMonitor: NWPathMonitor?
    internal let networkQueue = DispatchQueue(label: "com.licenseseat.sdk.network")
    #endif

    /// Timer for automatic validation
    nonisolated(unsafe) internal var validationTimer: Timer?

    /// Concurrency task for automatic validation (run-loop independent)
    internal var validationTask: Task<Void, Never>?

    /// Concurrency task for standalone heartbeat pings
    internal var heartbeatTask: Task<Void, Never>?

    /// Initialization and one-shot background work are retained so reset,
    /// deactivation, and forced reconfiguration can cancel stale operations.
    internal var initializationTask: Task<Void, Never>?
    internal var backgroundValidationTask: Task<Void, Never>?
    internal var offlineSyncTask: Task<Void, Never>?

    /// Timer for connectivity polling (fallback when NWPathMonitor unavailable)
    nonisolated(unsafe) internal var connectivityTimer: Timer?

    /// Timer for offline token refresh
    nonisolated(unsafe) internal var offlineRefreshTimer: Timer?

    /// Current auto-validation license key
    internal var currentAutoLicenseKey: String?

    /// Online/offline status
    public internal(set) var isOnline = true

    /// Last offline validation result to avoid duplicate events
    internal var lastOfflineValidation: ValidationResponse?

    /// Identifies the newest activation request. Main-actor isolation prevents
    /// data races, but actor reentrancy still allows an older network response
    /// to arrive after a newer activation or reset unless it is correlated.
    internal var currentActivationRequestID: UUID?
    internal var currentValidationRequestID: UUID?
    internal var currentHeartbeatRequestID: UUID?
    internal var currentOfflineSyncRequestID: UUID?

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

        initializationTask = Task { @MainActor [weak self] in
            await self?.initialize()
        }
    }

    /// Initialize SDK components
    private func initialize() async {
        guard !Task.isCancelled else { return }
        log("LicenseSeat SDK initialized", config)

        // Set up network monitoring
        setupNetworkMonitoring()

        // Check for cached license
        if let cachedLicense = cache.getLicense() {
            if config.deviceIdentifier == nil {
                DeviceIdentifier.adoptCachedLicenseIdentifier(cachedLicense.deviceId)
            }
            eventBus.emit("license:loaded", cachedLicense)

            // Complete local verification before starting the online request.
            // Ordering these operations prevents a late local task from
            // overwriting an authoritative invalid response from the server.
            if let offlineResult = await quickVerifyCachedOfflineLocal() {
                guard !Task.isCancelled else { return }
                if cache.updateValidation(offlineResult) {
                    if offlineResult.valid {
                        eventBus.emit("validation:offline-success", offlineResult)
                    } else {
                        eventBus.emit("validation:offline-failed", offlineResult)
                    }
                    lastOfflineValidation = offlineResult
                } else {
                    eventBus.emit("validation:offline-failed", [
                        "code": "cache_error"
                    ])
                }
            }

            // Start auto-validation and heartbeat if API key is configured
            if config.apiKey != nil, !Task.isCancelled {
                startAutoValidation(licenseKey: cachedLicense.licenseKey)
                startHeartbeat()
                scheduleOfflineRefresh()

                // Launch-time online validation follows the same opt-out as
                // periodic validation. Hosts that set the interval to zero own
                // the online cadence; local signed-cache verification above,
                // heartbeat, and offline-token refresh remain independent.
                if config.automaticValidationEnabled {
                    startBackgroundValidation(for: cachedLicense)
                }
            }
        }
    }

    /// Start the opt-in launch validation without making initialization own
    /// URLSession cancellation. FoundationNetworking can otherwise be left
    /// completing a request while reset tears down its scheduler task.
    private func startBackgroundValidation(for cachedLicense: License) {
        backgroundValidationTask?.cancel()
        backgroundValidationTask = Task { @MainActor [weak self] in
            let operation = Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    _ = try await self.validate(licenseKey: cachedLicense.licenseKey)
                } catch {
                    self.log("Background validation failed:", error)

                    if let apiError = error as? APIError,
                       apiError.status == 401 || apiError.status == 501 {
                        self.log("Authentication issue during validation, using cached license data")
                        self.eventBus.emit("validation:auth-failed", [
                            "licenseKey": cachedLicense.licenseKey,
                            "error": error,
                            "cached": true
                        ])
                    }
                }
            }
            await operation.value
        }
    }

    /// Await launch-time cache verification before beginning a public network
    /// operation. This prevents initialization and an immediate activation or
    /// reset from racing over the same protected state.
    internal func waitForInitialization() async {
        await initializationTask?.value
    }

    // MARK: - Lifecycle and Invalidation

    /// Apply a terminal server decision consistently no matter which endpoint
    /// observed it (validation, heartbeat, or offline-token refresh).
    internal func cachedLicenseMatches(_ identity: CachedLicenseIdentity) -> Bool {
        guard let currentLicense = cache.getLicense() else { return false }
        return CachedLicenseIdentity(currentLicense) == identity
    }

    internal func handleAuthoritativeInvalidation(
        _ error: APIError,
        expectedIdentity: CachedLicenseIdentity
    ) {
        guard cachedLicenseMatches(expectedIdentity) else { return }

        cancelBackgroundLicenseOperations()
        cache.clear()
        stopAutoValidation()
        stopHeartbeat()
        stopOfflineRefresh()
        currentAutoLicenseKey = nil
        lastOfflineValidation = nil

        eventBus.emit("license:revoked", [
            "code": error.code ?? "unknown",
            "status": error.status,
            "message": error.message
        ])
    }

    internal func cancelBackgroundLicenseOperations() {
        backgroundValidationTask?.cancel()
        backgroundValidationTask = nil
        offlineSyncTask?.cancel()
        offlineSyncTask = nil
    }

    /// Stop all work owned by an instance that is being replaced, without
    /// deleting the protected activation that its replacement should adopt.
    internal func shutdown() {
        currentActivationRequestID = nil
        currentValidationRequestID = nil
        currentHeartbeatRequestID = nil
        currentOfflineSyncRequestID = nil
        initializationTask?.cancel()
        initializationTask = nil
        cancelBackgroundLicenseOperations()
        validationTimer?.invalidate()
        validationTimer = nil
        connectivityTimer?.invalidate()
        connectivityTimer = nil
        offlineRefreshTimer?.invalidate()
        offlineRefreshTimer = nil
        validationTask?.cancel()
        validationTask = nil
        heartbeatTask?.cancel()
        heartbeatTask = nil
        apiClient.onNetworkStatusChange = nil
        #if canImport(Network)
        networkMonitor?.cancel()
        networkMonitor = nil
        #endif
    }

    internal func log(_ items: Any...) {
        guard config.debug else { return }
        let message = items.map { "\($0)" }.joined(separator: " ")
        print("[LicenseSeat SDK]", message)
    }

    deinit {
        initializationTask?.cancel()
        backgroundValidationTask?.cancel()
        offlineSyncTask?.cancel()
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
