# Event Reference & Best-Practices

A concise, single-page cheatsheet listing every SDK event you may care about, grouped by **concern** so teams can wire the right observers quickly.

| Concern | Subscribe To | Typical Action |
|---------|--------------|----------------|
| **License activated / loaded** | `activation:success`, `license:loaded` | Unlock full UI, start trials, analytics. |
| **Online validation success** | `validation:success` | Refresh entitlement UI. |
| **Offline validation success** | `validation:offline-success` | Show *offline* banner. |
| **Validation failed (semantic)** | `validation:failed`, `license:revoked` | Immediately lock premium features, cancel long-running tasks (recordings, uploads …). |
| **Validation failed (transient)** | `validation:auto-failed` | Keep UI but surface *connecting…* indicator. |
| **Network status** | `network:online`, `network:offline` | Grey-out buttons, show banners. |
| **Deactivation** | `deactivation:success` | Wipe user data, redirect to activation flow. |

## SwiftUI Example – auto-dismiss pop-over on logout / revoke

```swift
.onReceive(LicenseSeat.statusPublisher) { status in
    if case .inactive = status {
        popover.dismiss()
    }
}
```

## Testing Checklist

1. **Happy-path:** Activate → Validation 200 → `.active`.
2. **Revoke flow:** Revoke on server → wait ≤ auto-validate interval – expect `license:revoked` → UI locked.
3. **Network outage:** Simulate 5xx or no-network → expect `validation:auto-failed` + (optionally) `.offlineValid` when cache present.
4. **Grace-period expiry:** Advance clock / tamper → expect `.offlineInvalid`.

---
> Tip  Set `strictOfflineFallback = true` (default) for production so revoked licences NEVER fall back to cache. 