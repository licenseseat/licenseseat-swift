///
///  LicenseSeatStore.swift
///  LicenseSeatSDK
///
///  Created by LicenseSeat on 2025.
///
///  A high-level, observable façade on top of ``LicenseSeat`` that provides:
///  • Zero-configuration shared instance via ``LicenseSeatStore.shared``
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
///  LicenseSeatStore.shared.configure(apiKey: "prod_xxx")
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
    private(set) var seat: LicenseSeat?
    
    // MARK: – Initializers
    /// Creates a *detached* store that is not connected to the shared singleton. Useful for tests.
    public init(config: LicenseSeatConfig = .default, urlSession: URLSession? = nil) {
        self.seat = LicenseSeat(config: config, urlSession: urlSession)
        status = self.seat?.getStatus() ?? .inactive(message: "Not configured")
        subscribeToSeat()
    }
    
    /// Internal default initializer used by the shared instance.
    private init() { /* lazily configured via `configure` */ }
    
    // MARK: – Configuration
    /// Configures the shared store. The first call wins unless `force` is true.
    /// - Parameters:
    ///   - apiKey: Your LicenseSeat API key.
    ///   - apiBaseURL: Base URL for the LicenseSeat backend. Defaults to production (`LicenseSeatConfig.productionAPIBaseURL`).
    ///   - force: Recreate the underlying ``LicenseSeat`` even if it has been configured before.
    ///   - customize: Closure to modify the default ``LicenseSeatConfig`` before initialization.
    public func configure(apiKey: String,
                          apiBaseURL: URL? = nil,
                          force: Bool = false,
                          urlSession: URLSession? = nil,
                          options customize: (inout LicenseSeatConfig) -> Void = { _ in }) {
        if seat != nil && !force { return }

        var cfg = LicenseSeatConfig.default
        cfg.apiKey = apiKey
        if let apiBaseURL {
            cfg.apiBaseUrl = apiBaseURL.absoluteString
        }
        customize(&cfg)

        seat = LicenseSeat(config: cfg, urlSession: urlSession)
        status = seat?.getStatus() ?? .inactive(message: "Uninitialized")
        subscribeToSeat()
    }
    
    // MARK: – Public pass-through API
    @discardableResult
    public func activate(_ key: String,
                         options: ActivationOptions = .init()) async throws -> License {
        guard let seat else { throw LicenseSeatStoreError.notConfigured }
        let license = try await seat.activate(licenseKey: key, options: options)
        // Immediately refresh local status so callers don't depend on Combine delivery timing.
        self.status = seat.getStatus()
        return license
    }
    
    public func deactivate() async throws {
        guard let seat else { throw LicenseSeatStoreError.notConfigured }
        try await seat.deactivate()
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
    
    // MARK: – Private helpers
    private func subscribeToSeat() {
        #if canImport(Combine)
        seat?.statusPublisher
            .receive(on: RunLoop.main)
            .assign(to: &$status)
        
        // Listen for auto-validation cycles to keep `nextAutoValidationAt` in sync.
        seat?.eventPublisher(for: "autovalidation:cycle")
            .compactMap { $0.dictionary?["nextRunAt"] as? Date }
            .receive(on: RunLoop.main)
            .assign(to: &$nextAutoValidationAt)
        
        // When auto-validation stops, clear the date so UI knows it's inactive.
        seat?.eventPublisher(for: "autovalidation:stopped")
            .map { _ in Optional<Date>.none }
            .receive(on: RunLoop.main)
            .assign(to: &$nextAutoValidationAt)
        #endif
    }
    
    /// Generate a redacted diagnostic report for support tickets
    public func debugReport() -> [String: Any] {
        var report: [String: Any] = [
            "sdk_version": "2.0.0",
            "status": String(describing: status),
            "has_seat": seat != nil,
            "next_validation": nextAutoValidationAt?.timeIntervalSince1970 ?? "none"
        ]
        
        if let license = seat?.currentLicense() {
            report["license_key_prefix"] = String(license.licenseKey.prefix(8)) + "..."
            report["device_id_hash"] = license.deviceIdentifier.hashValue
            report["activated_at"] = license.activatedAt.timeIntervalSince1970
            report["last_validated"] = license.lastValidated.timeIntervalSince1970
        }
        
        return report
    }
}

// MARK: – SwiftUI Quality-of-life Sugar

#if canImport(SwiftUI)
/// Property-wrapper exposing the current ``LicenseStatus`` inside SwiftUI views.
@propertyWrapper
public struct LicenseState: DynamicProperty {
    @StateObject private var store = LicenseSeatStore.shared
    public var wrappedValue: LicenseStatus { store.status }
    public var projectedValue: LicenseStatus { store.status }
    public init() {}
}

/// Property-wrapper for checking a specific entitlement's status inside SwiftUI views.
@propertyWrapper
public struct EntitlementState: DynamicProperty {
    @StateObject private var store = LicenseSeatStore.shared
    private let entitlementId: String
    
    public var wrappedValue: Bool { 
        store.entitlement(entitlementId).active 
    }
    
    public var projectedValue: EntitlementStatus { 
        store.entitlement(entitlementId) 
    }
    
    public init(_ id: String) {
        self.entitlementId = id
    }
}

extension View {
    /// Injects the shared ``LicenseSeatStore`` into the environment.
    @MainActor
    public func licenseSeat(_ store: LicenseSeatStore? = nil) -> some View {
        let target = store ?? LicenseSeatStore.shared
        return environmentObject(target)
    }
}
#endif

// MARK: – Convenience errors

public enum LicenseSeatStoreError: LocalizedError {
    case notConfigured

    public var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "LicenseSeatStore.shared must be configured before use. Call `configure(apiKey:)` early in your application's lifecycle."
        }
    }
}

// MARK: - ObservableObject Conformance

#if canImport(Combine)
extension LicenseSeatStore: ObservableObject {}
#endif 