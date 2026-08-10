//
//  LicenseSeatStore+SwiftUI.swift
//  LicenseSeatSDK
//
//  SwiftUI property wrappers and environment integration.
//

#if canImport(SwiftUI)
import SwiftUI

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
