//
//  LicenseStateSnapshot.swift
//  LicenseSeatSDK
//
//  Typed state accessors (#13), at parity with the Rust SDK's
//  state_snapshot / restore_license / trusted-source surface.
//

import Foundation

/// What established the license decision this process currently trusts.
public enum TrustedLicenseSource: String, Equatable, Sendable, CaseIterable {
    /// An authenticated online API response (activation or validation).
    case onlineResponse = "online_response"
    /// A locally verified signed offline artifact (machine file or legacy
    /// offline token).
    case signedOfflineArtifact = "signed_offline_artifact"
    /// An authoritative or conservative fail-closed denial: an online invalid
    /// result or a failed offline verification.
    case failClosedDenial = "fail_closed_denial"
}

/// A consistent, typed view of the SDK's license state at one instant.
///
/// Everything is read on the main actor in one pass, so the fields describe
/// the same decision. `license` and `validation` may come from the persisted
/// cache; `trustedSource` says whether *this process* has re-established
/// them (it is `nil` until an online response or a verified offline artifact
/// has, e.g. right after launch with no network and no offline artifact).
public struct LicenseStateSnapshot: Equatable, Sendable {
    /// Rich status, identical to ``LicenseSeat/getStatus()``.
    public let status: LicenseStatus
    /// Whether the most recent API operation considered the service reachable.
    public let isOnline: Bool
    /// The cached activation, if any.
    public let license: License?
    /// The cached validation decision for that activation, if any.
    public let validation: ValidationResponse?
    /// Unexpired entitlements of the current decision when it grants access
    /// (`status` is `.active` or `.offlineValid`); empty otherwise.
    public let activeEntitlements: [Entitlement]
    /// What established the decision this process trusts, or `nil`.
    public let trustedSource: TrustedLicenseSource?
    /// The protected clock-rollback watermark.
    public let lastSeenTimestamp: Date?
    /// Next scheduled automatic validation, if automatic validation runs.
    public let nextAutoValidationAt: Date?
}

/// The outcome of ``LicenseSeat/restoreLicense()``.
public struct RestoreResult {
    /// Whether this process re-established access for the cached license
    /// (an online response or a verified offline artifact). `false` whenever
    /// `error` is set, even if `status` still reports a persisted grant.
    public let restored: Bool
    /// Status after the restore attempt.
    public let status: LicenseStatus
    /// The cached activation after the attempt (`nil` if none, or if the
    /// server authoritatively invalidated it).
    public let license: License?
    /// The validation result that drove the final state, if any.
    public let validation: ValidationResponse?
    /// The error that prevented an online or offline decision, if any.
    public let error: (any Error)?
}
