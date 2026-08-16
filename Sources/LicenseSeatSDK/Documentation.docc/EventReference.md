# Event Reference

Observe license lifecycle transitions without polling SDK state.

## Subscription APIs

The closure API returns a cancellable. Retain it for as long as events are needed:

```swift
let subscription = LicenseSeat.shared.on("validation:success") { payload in
    refreshLicensedUI()
}
```

Combine provides a filtered publisher and a true all-events publisher. The all-events publisher receives newly introduced event names automatically.

```swift
LicenseSeat.shared.eventPublisher
    .sink { event in
        print(event.name)
    }
    .store(in: &cancellables)

LicenseSeat.shared.eventPublisher(for: "heartbeat:error")
    .sink { event in
        report(event.error)
    }
    .store(in: &cancellables)
```

Handlers are delivered on the main queue.

## Lifecycle Events

| Area | Events |
| --- | --- |
| Cached state | `license:loaded`, `sdk:reset` |
| Activation | `activation:start`, `activation:success`, `activation:error` |
| Validation | `validation:start`, `validation:success`, `validation:failed`, `validation:error` |
| Offline validation | `validation:offline-success`, `validation:offline-failed` |
| Background work | `validation:auto-failed`, `validation:auth-failed`, `autovalidation:cycle`, `autovalidation:stopped` |
| Invalidation | `license:revoked` |
| Deactivation | `deactivation:start`, `deactivation:success`, `deactivation:error` |
| Connectivity | `network:online`, `network:offline` |
| Offline assets | `offlineToken:fetching`, `offlineToken:fetched`, `offlineToken:fetchError`, `offlineToken:ready`, `offlineToken:verified`, `offlineToken:verificationFailed` |
| Machine files | `machineFile:fetching`, `machineFile:fetched`, `machineFile:fetchError`, `machineFile:ready`, `machineFile:verified`, `machineFile:verificationFailed` |
| Heartbeat | `heartbeat:success`, `heartbeat:error` |
| General errors | `sdk:error` |

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
