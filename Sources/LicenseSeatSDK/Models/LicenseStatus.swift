//
//  LicenseStatus.swift
//  LicenseSeatSDK
//
//  Created by LicenseSeat on 2025.
//  Copyright © 2025 LicenseSeat. All rights reserved.
//

import Foundation

/// Represents the current status of a license
public enum LicenseStatus: Equatable, Sendable {
    /// No license activated
    case inactive(message: String)

    /// License pending validation
    case pending(message: String)

    /// License is invalid
    case invalid(message: String)

    /// License is invalid (offline check)
    case offlineInvalid(message: String)

    /// License is active
    case active(details: LicenseStatusDetails)

    /// License is valid (offline check)
    case offlineValid(details: LicenseStatusDetails)
}

/// Detailed license status information
public struct LicenseStatusDetails: Equatable, Sendable {
    /// License key
    public let license: String

    /// Device identifier
    public let device: String

    /// Activation date
    public let activatedAt: Date

    /// Last validation date
    public let lastValidated: Date

    /// Active entitlements
    public let entitlements: [Entitlement]
}

/// Entitlement check result
public struct EntitlementStatus: Equatable, Sendable {
    /// Whether the entitlement is active
    public let active: Bool

    /// Reason for inactive status
    public let reason: EntitlementInactiveReason?

    /// Expiration date (if applicable)
    public let expiresAt: Date?

    /// The entitlement details (if found)
    public let entitlement: Entitlement?
}

/// Reason for inactive entitlement
public enum EntitlementInactiveReason: String, Equatable, Sendable {
    case noLicense = "no_license"
    case notFound = "not_found"
    case expired = "expired"
} 