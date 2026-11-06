# Event Reference

Observe license lifecycle transitions without polling SDK state.

## Subscription APIs

The closure API returns a cancellable. Retain it for as long as events are needed:

```swift
let subscription = LicenseSeat.shared.on(.validationSuccess) { payload in
    refreshLicensedUI()
}
```

Every event has a typed ``EventKind`` case whose raw value is the wire name,
so `on(.validationSuccess)` and `on("validation:success")` are
interchangeable. Prefer the enum: a misspelled case does not compile, while a
misspelled string silently never fires. Each case documents its payload.

Combine provides a filtered publisher and a true all-events publisher. The all-events publisher receives newly introduced event names automatically.

```swift
LicenseSeat.shared.eventPublisher
    .sink { event in
        print(event.name, event.kind as Any) // kind is nil only for names newer than this SDK
    }
    .store(in: &cancellables)

LicenseSeat.shared.eventPublisher(for: .heartbeatError)
    .sink { event in
        report(event.error)
    }
    .store(in: &cancellables)
```

Handlers are delivered on the main queue.

## Lifecycle Events

| Area | Events (`EventKind` case) |
| --- | --- |
| Cached state | `license:loaded` (`.licenseLoaded`), `sdk:reset` (`.sdkReset`), `sdk:error` (`.sdkError`) |
| Activation | `activation:start` (`.activationStart`), `activation:success` (`.activationSuccess`), `activation:error` (`.activationError`) |
| Validation | `validation:start` (`.validationStart`), `validation:success` (`.validationSuccess`), `validation:failed` (`.validationFailed`), `validation:error` (`.validationError`) |
| Offline validation | `validation:offline-success` (`.validationOfflineSuccess`), `validation:offline-failed` (`.validationOfflineFailed`) |
| Background work | `validation:auto-failed` (`.validationAutoFailed`), `validation:auth-failed` (`.validationAuthFailed`), `autovalidation:cycle` (`.autoValidationCycle`), `autovalidation:stopped` (`.autoValidationStopped`) |
| Invalidation | `license:revoked` (`.licenseRevoked`) |
| Deactivation | `deactivation:start` (`.deactivationStart`), `deactivation:success` (`.deactivationSuccess`), `deactivation:error` (`.deactivationError`) |
| Connectivity | `network:online` (`.networkOnline`), `network:offline` (`.networkOffline`) |
| Offline refresh | `offlineAssets:ready` (`.offlineAssetsReady`), `offlineAssets:fetchError` (`.offlineAssetsFetchError`) |
| Legacy offline tokens | `offlineToken:fetching` (`.offlineTokenFetching`), `offlineToken:fetched` (`.offlineTokenFetched`), `offlineToken:fetchError` (`.offlineTokenFetchError`), `offlineToken:ready` (`.offlineTokenReady`), `offlineToken:verified` (`.offlineTokenVerified`), `offlineToken:verificationFailed` (`.offlineTokenVerificationFailed`) |
| Machine files | `machineFile:fetching` (`.machineFileFetching`), `machineFile:fetched` (`.machineFileFetched`), `machineFile:fetchError` (`.machineFileFetchError`), `machineFile:ready` (`.machineFileReady`), `machineFile:verified` (`.machineFileVerified`), `machineFile:verificationFailed` (`.machineFileVerificationFailed`) |
| Heartbeat | `heartbeat:success` (`.heartbeatSuccess`), `heartbeat:error` (`.heartbeatError`) |

`license:revoked` is the compatibility event for any authoritative terminal invalidation, including suspended, expired, inactive, missing-license, and missing-activation decisions. Inspect its dictionary fields `code`, `status`, and `message` instead of assuming the reason is literally revocation.

## Status and Entitlement Publishers

``LicenseSeat/statusPublisher-type.property`` emits after cached state loads and after activation, validation, invalidation, deactivation, or reset changes status.

``LicenseSeat/entitlementPublisher(for:)`` emits when activation or any validation/invalidation transition can change access.

```swift
LicenseSeat.statusPublisher
    .sink { status in
        switch status {
        case .active, .offlineValid:
            unlockUI()
        default:
            lockUI()
        }
    }
    .store(in: &cancellables)
```

## Testing Checklist

1. Activate and assert `activation:success` plus `.active`.
2. Return a valid validation and assert `validation:success`.
3. Return HTTP 200 with `valid: false` and assert `validation:failed`, cached token removal, and locked entitlements.
4. Return a terminal API error and assert `license:revoked` and inactive state.
5. Simulate a transport failure with a valid signed grant and assert `validation:offline-success` plus `.offlineValid`.
6. Simulate an expired or mismatched token and assert `validation:offline-failed` with no access.
7. Verify heartbeat decode success and failure events, not only request counts.
