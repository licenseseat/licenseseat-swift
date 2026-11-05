//
//  EventKind.swift
//  LicenseSeatSDK
//
//  Every event the SDK emits, as a typed enum over the string bus (#10).
//

import Foundation

/// Every event the SDK emits.
///
/// The raw value is the wire name used by the string API, so the two are
/// interchangeable: `seat.on(.licenseRevoked) { … }` and
/// `seat.on("license:revoked") { … }` observe the same event. Prefer the enum:
/// a misspelled case does not compile, while a misspelled string silently
/// never fires.
///
/// Payloads are delivered as `Any` for source compatibility; the documented
/// shape of each is listed per case. Dictionary payloads use `String` keys.
public enum EventKind: String, CaseIterable, Sendable {
    // MARK: Cached state

    /// A cached activation was loaded at startup. Payload: ``License``.
    case licenseLoaded = "license:loaded"
    /// ``LicenseSeat/reset()`` cleared SDK state. Payload: empty dictionary.
    case sdkReset = "sdk:reset"
    /// A background operation could not run (for example an offline refresh
    /// with no cached activation, or no signature crypto on this platform).
    /// Payload: `["message": String]`.
    case sdkError = "sdk:error"

    // MARK: Activation

    /// Activation request started. Payload: `["licenseKey", "deviceId"]`.
    case activationStart = "activation:start"
    /// Activation committed. Payload: ``License``.
    case activationSuccess = "activation:success"
    /// Activation failed. Payload: `["licenseKey": String, "error": Error]`.
    case activationError = "activation:error"

    // MARK: Validation

    /// Online validation started. Payload: `["licenseKey": String]`.
    case validationStart = "validation:start"
    /// The server accepted the license. Payload: ``ValidationResponse``.
    case validationSuccess = "validation:success"
    /// The server answered `valid: false`. Payload: ``ValidationResponse``.
    case validationFailed = "validation:failed"
    /// The validation request failed (transport or API error) before any
    /// offline fallback. Payload: `["licenseKey": String, "error": Error]`.
    case validationError = "validation:error"
    /// Offline verification accepted a cached artifact. Payload:
    /// ``ValidationResponse``.
    case validationOfflineSuccess = "validation:offline-success"
    /// Offline verification rejected a cached artifact (or found none).
    /// Payload: ``ValidationResponse``, or `["code": String]` on a storage error.
    case validationOfflineFailed = "validation:offline-failed"
    /// Launch-time online validation hit an authentication problem (401/501)
    /// and kept the cached license. Payload:
    /// `["licenseKey": String, "error": Error, "cached": true]`.
    case validationAuthFailed = "validation:auth-failed"
    /// A scheduled automatic validation failed. Payload:
    /// `["licenseKey": String, "error": Error]`.
    case validationAutoFailed = "validation:auto-failed"

    // MARK: Automatic validation

    /// An automatic validation cycle was scheduled. Payload:
    /// `["nextRunAt": Date]`.
    case autoValidationCycle = "autovalidation:cycle"
    /// Automatic validation stopped. Payload: empty dictionary.
    case autoValidationStopped = "autovalidation:stopped"

    // MARK: Invalidation

    /// The server authoritatively invalidated the cached license (revoked,
    /// expired, suspended, not active, not found, device not activated, 410).
    /// Payload: `["code": String, "status": Int, "message": String]`.
    case licenseRevoked = "license:revoked"

    // MARK: Deactivation

    /// Deactivation request started. Payload: ``License``.
    case deactivationStart = "deactivation:start"
    /// Deactivation completed. Payload: `["licenseKey": String,
    /// "localStateCleared": Bool]`.
    case deactivationSuccess = "deactivation:success"
    /// Deactivation failed. Payload: `["error": Error, "license": License]`.
    case deactivationError = "deactivation:error"

    // MARK: Connectivity

    /// The API became reachable again. Payload: empty dictionary.
    case networkOnline = "network:online"
    /// The API became unreachable. Payload: empty dictionary.
    case networkOffline = "network:offline"

    // MARK: Heartbeat

    /// A heartbeat was acknowledged. Payload: empty dictionary.
    case heartbeatSuccess = "heartbeat:success"
    /// A heartbeat failed. Payload: `["error": Error]`.
    case heartbeatError = "heartbeat:error"

    // MARK: Offline assets

    /// An offline refresh produced an artifact. Payload: `["artifact":
    /// "machine_file" | "offline_token", "kid": String, …]`.
    case offlineAssetsReady = "offlineAssets:ready"
    /// An offline refresh produced no artifact. Payload: `["error": Error]`.
    case offlineAssetsFetchError = "offlineAssets:fetchError"

    /// Legacy offline-token request started. Payload: `["licenseKey": String]`.
    case offlineTokenFetching = "offlineToken:fetching"
    /// Legacy offline token received. Payload: `["licenseKey": String]`.
    case offlineTokenFetched = "offlineToken:fetched"
    /// Legacy offline-token refresh failed. Payload: `["error": Error]`
    /// (plus `"licenseKey"` when an activation was cached).
    case offlineTokenFetchError = "offlineToken:fetchError"
    /// Legacy offline token verified and cached. Payload:
    /// `["kid": String, "exp": Int]`.
    case offlineTokenReady = "offlineToken:ready"
    /// A legacy offline token verified. Payload: `["kid": String]`.
    case offlineTokenVerified = "offlineToken:verified"
    /// A legacy offline token failed verification. Payload: `["kid": String]`.
    case offlineTokenVerificationFailed = "offlineToken:verificationFailed"

    // MARK: Machine files

    /// Machine-file checkout started. Payload: `["licenseKey": String]`.
    case machineFileFetching = "machineFile:fetching"
    /// Machine file received. Payload: `["licenseKey": String]`.
    case machineFileFetched = "machineFile:fetched"
    /// Machine-file checkout failed. Payload:
    /// `["licenseKey": String, "error": Error]`.
    case machineFileFetchError = "machineFile:fetchError"
    /// Machine file verified and cached. Payload:
    /// `["kid": String, "expiresAt": Date?]`.
    case machineFileReady = "machineFile:ready"
    /// A machine file verified. Payload: `["kid": String]`.
    case machineFileVerified = "machineFile:verified"
    /// A machine file failed verification. Payload:
    /// `["kid": String, "code": String]`.
    case machineFileVerificationFailed = "machineFile:verificationFailed"
}
