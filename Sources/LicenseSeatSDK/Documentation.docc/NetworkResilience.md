# Network Resilience

Understand retries, connectivity transitions, offline fallback, and authoritative invalidation.

## Retry Policy

The SDK uses URLSession and exponential backoff. `maxRetries` is the number of retries after the initial request.

```swift
let config = LicenseSeatConfig(
    apiKey: "pk_live_…",
    productSlug: "my-product",
    maxRetries: 3,
    retryDelay: 1
)
```

With these values, retry delays are approximately 1, 2, and 4 seconds. Negative retry counts are treated as zero. Negative or non-finite base delays do not trap the process.

Requests are retried for:

- URLSession transport errors;
- HTTP 408 and 429;
- HTTP 500 and 502 through 599.

The SDK does not retry ordinary 4xx business decisions or HTTP 501. Caller cancellation is neither retried nor reported as an offline transition. A decoded success payload that violates the expected identity contract also fails immediately.

## Offline Fallback

The default mode is `.networkOnly`:

```swift
var config = LicenseSeatConfig.default
config.offlineFallbackMode = .networkOnly
```

This mode attempts the cached signed token for transport errors, status 0, HTTP 408, and 5xx responses. It does not use offline data to hide a 4xx response.

`.always` also attempts local verification for non-terminal failures. Terminal license decisions are processed before fallback in both modes, so revoked, suspended, expired, inactive, missing, or deactivated licenses cannot be resurrected from cache.

An offline token must still pass its signature, canonical-payload, identity, fingerprint, time, license-expiry, grace, and rollback checks. A network outage is not sufficient to grant access.

## Connectivity Lifecycle

Apple platforms use `NWPathMonitor`. Other supported environments use periodic `/health` checks controlled by `networkRecheckInterval`.

When connectivity is lost, automatic validation, heartbeat, and offline refresh stop. The active license key is retained. When connectivity returns, the SDK restarts those schedules and synchronizes offline assets.

```swift
let subscription = LicenseSeat.shared.on("network:offline") { _ in
    showOfflineBanner()
}

let recovery = LicenseSeat.shared.on("network:online") { _ in
    hideOfflineBanner()
}
```

With Combine:

```swift
LicenseSeat.shared.networkStatusPublisher
    .removeDuplicates()
    .sink { isOnline in
        networkBannerVisible = !isOnline
    }
    .store(in: &cancellables)
```

## Invalid Offline Fallback

If the network is unavailable and no valid signed grant exists, validation fails closed. The SDK emits `validation:offline-failed`, but it retains the automatic-validation identity so a future server recovery or network reconnection can validate again. A transient outage therefore does not permanently disable recovery.

## Cache Invalidation Policy

The SDK clears cached grants for HTTP 410 or terminal codes such as:

- `license_not_found`;
- `revoked`, `suspended`, or `expired`;
- `not_active`;
- `device_not_activated` or `activation_not_found`;
- their `license_…` compatibility forms.

Invalidation is scoped to the exact cached license key, fingerprint, and activation ID that initiated the request. An unrelated key—or a late response for a replaced activation—cannot erase current state.

HTTP 401, 403, 408, 429, malformed-request errors, and non-terminal 404/422 responses do not automatically purge a signed grant.

## Application Guidance

- Keep `.networkOnly` unless a documented product requirement justifies `.always`.
- Do not add an application-level bypass after signature or claim verification fails.
- Treat `.active` and `.offlineValid` as the licensed states.
- Surface connectivity separately from license validity.
- Keep retry counts and timer intervals bounded for the product's UX.
- Test outage, 5xx, 403 scope failure, revoked, expired-token, and reconnection paths.

See <doc:OfflineValidation> for the cryptographic decision flow.
