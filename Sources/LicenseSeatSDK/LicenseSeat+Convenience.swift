//
//  LicenseSeat+Convenience.swift
//  LicenseSeatSDK
//
//  Public options and process-wide convenience APIs.
//

import Foundation
#if canImport(Combine)
import Combine
#endif

// MARK: - Supporting Types

/// Options for license activation
///
/// Metadata must contain JSON-compatible values. The unchecked conformance
/// preserves the SDK's existing public `Sendable` API while the main-actor
/// client serializes the payload before it crosses any additional boundary.
public struct ActivationOptions: @unchecked Sendable {
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
        let instance = LicenseSeat(config: cfg)
        installShared(instance)
        LicenseSeatStore.shared.adoptSharedSeat(instance)
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
