///
///  LicenseSeatStore.swift
///  LicenseSeatSDK
///
///  Created by LicenseSeat on 2025.
///
///  A high-level, observable façade on top of ``LicenseSeat`` that provides:
///  • A shared instance configured with an API key and product slug
///  • SwiftUI-friendly @Published `status` for real-time UI updates
///  • Pass-through helpers for the most common operations (`activate`, `deactivate`, `entitlement`)
///  • Optional quality-of-life sugar such as property-wrappers and view-modifiers (SwiftUI only)
///
///  The underlying ``LicenseSeat`` instance remains fully accessible via the `seat` property.
///  Advanced clients can still create additional stores or interact with ``LicenseSeat`` directly.
///
///  The class is annotated with ``@MainActor`` to guarantee that state changes are
///  delivered on the main thread – a requirement for SwiftUI and AppKit bindings.
///
///  Integration example:
///  ```swift
///  // Application start-up
///  LicenseSeatStore.shared.configure(
///      apiKey: "pk_live_…",
///      productSlug: "my-product"
///  )
///  
///  // Somewhere in SwiftUI
///  struct ContentView: View {
///      @LicenseState private var license
///      
///      var body: some View {
///          switch license {
///          case .active:  MainAppView()
///          default:       ActivationView()
///          }
///      }
///  }
///  ```
///
///  The implementation purposefully avoids exposing a public initializer for the
///  shared instance. If dependency-injection or multiple stores are desired the
///  caller can still create them via ``init(config:)``.
///

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(Combine)
import Combine
#endif
#if canImport(SwiftUI)
import SwiftUI
#endif

/// Thread-safe, observable façade around ``LicenseSeat``.
@MainActor
public final class LicenseSeatStore {
    // MARK: – Public static API
    /// Canonical shared instance for the application.
    public static let shared = LicenseSeatStore()
    
    // MARK: – Published state
    /// Reactive mirror of ``LicenseSeat.getStatus()``.
    #if canImport(Combine)
    @Published public private(set) var status: LicenseStatus = .inactive(message: "Not configured")
    #else
    public private(set) var status: LicenseStatus = .inactive(message: "Not configured")
    #endif

    /// Timestamp of the next scheduled auto-validation cycle (if any).
    #if canImport(Combine)
    @Published public private(set) var nextAutoValidationAt: Date?
    #else
    public private(set) var nextAutoValidationAt: Date?
    #endif
    
    // MARK: – Internal properties
    public private(set) var seat: LicenseSeat?
    #if canImport(Combine)
    private var subscriptions = Set<AnyCancellable>()
    #endif
    
    // MARK: – Initializers
    /// Creates a *detached* store that is not connected to the shared singleton. Useful for tests.
    public init(config: LicenseSeatConfig = .default, urlSession: URLSession? = nil) {
        self.seat = LicenseSeat(config: config, urlSession: urlSession)
        status = seat?.getStatus() ?? .inactive(message: "Not configured")
        subscribeToSeat()
    }
    
    /// Internal default initializer used by the shared instance.
    private init() { /* lazily configured via `configure` */ }
    
    // MARK: – Configuration
    /// Configures the store with an explicit product. The first call wins unless `force` is true.
    /// - Parameters:
    ///   - apiKey: Your LicenseSeat API key.
    ///   - productSlug: Product identifier required by license operations.
    ///   - apiBaseURL: Base URL for the LicenseSeat backend. Defaults to
    ///     production (`LicenseSeatConfig.productionAPIBaseURL`).
    ///   - force: Recreate the underlying ``LicenseSeat`` even if it has been configured before.
    ///   - urlSession: Optional session injection for custom networking or tests.
    ///   - customize: Closure to modify the default ``LicenseSeatConfig`` before initialization.
    /// - Returns: `true` when the configuration was applied. A second call
    ///   without `force` logs a warning, leaves the existing instance intact,
    ///   and returns `false`.
    @discardableResult
    public func configure(apiKey: String,
                          productSlug: String,
                          apiBaseURL: URL? = nil,
                          force: Bool = false,
                          urlSession: URLSession? = nil,
                          options customize: (inout LicenseSeatConfig) -> Void = { _ in }) -> Bool {
        guard canConfigure(force: force) else { return false }
        let config = configured(
            apiKey: apiKey,
            productSlug: productSlug,
            apiBaseURL: apiBaseURL,
            customize: customize
        )
        return configureInstance(
            config: config,
            force: force,
            urlSession: urlSession
        )
    }

    /// Compatibility overload for applications compiled against 0.4.1.
    ///
    /// Set `productSlug` in `options`, or migrate to
    /// ``configure(apiKey:productSlug:apiBaseURL:force:urlSession:options:)``.
    /// - Returns: `true` when the configuration was applied.
    @discardableResult
    public func configure(apiKey: String,
                          apiBaseURL: URL? = nil,
                          force: Bool = false,
                          urlSession: URLSession? = nil,
                          options customize: (inout LicenseSeatConfig) -> Void = { _ in }) -> Bool {
        guard canConfigure(force: force) else { return false }
        let config = configured(
            apiKey: apiKey,
            productSlug: nil,
            apiBaseURL: apiBaseURL,
            customize: customize
        )
        return configureInstance(
            config: config,
            force: force,
            urlSession: urlSession
        )
    }

    /// One predicate for both configuration entry points so a rejected call is
    /// always reported the same way instead of returning silently.
    private func canConfigure(force: Bool) -> Bool {
        guard seat != nil, !force else { return true }
        seat?.log(
            "[Warning] LicenseSeatStore is already configured.",
            "Ignoring this configure call; pass force: true to replace the existing instance."
        )
        return false
    }

    private func configured(
        apiKey: String,
        productSlug: String?,
        apiBaseURL: URL?,
        customize: (inout LicenseSeatConfig) -> Void
    ) -> LicenseSeatConfig {
        var config = LicenseSeatConfig.default
        config.apiKey = apiKey
        config.productSlug = productSlug
        if let apiBaseURL {
            config.apiBaseUrl = apiBaseURL.absoluteString
        }
        customize(&config)
        return config
    }

    @discardableResult
    private func configureInstance(
        config: LicenseSeatConfig,
        force: Bool,
        urlSession: URLSession?
    ) -> Bool {
        guard canConfigure(force: force) else { return false }

        if force {
            seat?.shutdown()
        }

        let instance = LicenseSeat(config: config, urlSession: urlSession)
        if self === LicenseSeatStore.shared {
            LicenseSeat.installShared(instance)
        }
        adoptSharedSeat(instance)
        return true
    }
    
    // MARK: – Public pass-through API
    @discardableResult
    public func activate(_ key: String,
                         options: ActivationOptions = .init()) async throws -> License {
        guard let seat else { throw LicenseSeatStoreError.notConfigured }
        defer { refreshStatus(from: seat) }
        let license = try await seat.activate(licenseKey: key, options: options)
        return license
    }

    /// Performs an immediate validation through the observable store facade.
    /// The mirrored status is refreshed before this method returns.
    @discardableResult
    public func validate(
        licenseKey: String,
        options: ValidationOptions = .init()
    ) async throws -> ValidationResponse {
        guard let seat else { throw LicenseSeatStoreError.notConfigured }
        defer { refreshStatus(from: seat) }
        let validation = try await seat.validate(licenseKey: licenseKey, options: options)
        return validation
    }
    
    public func deactivate() async throws {
        guard let seat else { throw LicenseSeatStoreError.notConfigured }
        defer { refreshStatus(from: seat) }
        try await seat.deactivate()
    }

    /// Sends an immediate heartbeat for the active license.
    public func heartbeat() async throws {
        guard let seat else { throw LicenseSeatStoreError.notConfigured }
        defer { refreshStatus(from: seat) }
        try await seat.heartbeat()
    }

    /// Clears the activation, signed offline assets, timers, and observable
    /// state while retaining the current SDK configuration.
    public func reset() {
        seat?.reset()
        status = seat?.getStatus() ?? .inactive(message: "Not configured")
        nextAutoValidationAt = nil
    }
    
    public func entitlement(_ id: String) -> EntitlementStatus {
        guard let seat else {
            return EntitlementStatus(
                active: false,
                reason: .noLicense,
                expiresAt: nil,
                entitlement: nil
            )
        }
        return seat.checkEntitlement(id)
    }
    
    #if canImport(Combine)
    public func entitlementPublisher(for id: String) -> AnyPublisher<EntitlementStatus, Never> {
        guard let seat else {
            let empty = EntitlementStatus(
                active: false,
                reason: .noLicense,
                expiresAt: nil,
                entitlement: nil
            )
            return Just(empty).eraseToAnyPublisher()
        }
        // Prepend current entitlement state so subscribers get an immediate value.
        return seat.entitlementPublisher(for: id)
            .prepend(seat.checkEntitlement(id))
            .eraseToAnyPublisher()
    }
    #endif

    /// Makes the store observe the canonical static SDK instance. Keeping this
    /// internal prevents applications from manufacturing divergent singleton
    /// state while allowing both supported configuration entry points to share
    /// one source of truth.
    internal func adoptSharedSeat(_ instance: LicenseSeat) {
        #if canImport(Combine)
        subscriptions.removeAll()
        #endif
        seat = instance
        status = instance.getStatus()
        nextAutoValidationAt = nil
        subscribeToSeat()
    }
    
    // MARK: – Private helpers
    private func subscribeToSeat() {
        #if canImport(Combine)
        subscriptions.removeAll()

        seat?.statusPublisher
            .receive(on: RunLoop.main)
            .filter { [weak self] newStatus in
                self?.status != newStatus
            }
            .sink { [weak self] status in
                self?.status = status
            }
            .store(in: &subscriptions)
        
        // Listen for auto-validation cycles to keep `nextAutoValidationAt` in sync.
        seat?.eventPublisher(for: "autovalidation:cycle")
            .compactMap { $0.dictionary?["nextRunAt"] as? Date }
            .receive(on: RunLoop.main)
            .sink { [weak self] date in
                self?.nextAutoValidationAt = date
            }
            .store(in: &subscriptions)
        
        // When auto-validation stops, clear the date so UI knows it's inactive.
        seat?.eventPublisher(for: "autovalidation:stopped")
            .map { _ in Optional<Date>.none }
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.nextAutoValidationAt = nil
            }
            .store(in: &subscriptions)
        #endif
    }

    private func refreshStatus(from seat: LicenseSeat) {
        let currentStatus = seat.getStatus()
        if status != currentStatus {
            status = currentStatus
        }
    }
    
    /// Generate a redacted diagnostic report for support tickets
    public func debugReport() -> [String: Any] {
        var report: [String: Any] = [
            "sdk_version": LicenseSeatConfig.sdkVersion,
            "status": redactedStatusName,
            "has_seat": seat != nil,
            "next_validation": nextAutoValidationAt?.timeIntervalSince1970 ?? "none"
        ]
        
        if let license = seat?.currentLicense() {
            report["activated_at"] = license.activatedAt.timeIntervalSince1970
            report["last_validated"] = license.lastValidated.timeIntervalSince1970
        }
        
        return report
    }

    private var redactedStatusName: String {
        switch status {
        case .inactive:
            return "inactive"
        case .pending:
            return "pending"
        case .invalid:
            return "invalid"
        case .offlineInvalid:
            return "offline_invalid"
        case .active:
            return "active"
        case .offlineValid:
            return "offline_valid"
        }
    }
}

// MARK: – Convenience errors

public enum LicenseSeatStoreError: LocalizedError {
    case notConfigured

    public var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "LicenseSeatStore.shared must be configured before use. "
                + "Call `configure(apiKey:productSlug:)` early in your application's lifecycle."
        }
    }
}

// MARK: - ObservableObject Conformance

#if canImport(Combine)
extension LicenseSeatStore: ObservableObject {}
#endif
