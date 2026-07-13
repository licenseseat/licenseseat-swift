# Offline Validation

Use a previously activated, device-bound license during a temporary network or server outage without weakening revocation handling.

## Overview

The current Swift SDK uses the LicenseSeat legacy signed-token endpoint for offline compatibility. The backend's newer encrypted machine-file flow is not yet exposed by this SDK.

After online activation, the SDK:

1. Requests a signed offline token for the activated fingerprint.
2. Resolves the token's Ed25519 public key from `/signing_keys/{keyId}`.
3. Verifies every signed claim before replacing a cached token.
4. Stores the activation, token, public key, and clock state in Keychain on Apple platforms.
5. Refreshes the token periodically and re-arms refresh after launch.

The server requires an active seat for the same fingerprint before it issues an offline token. A suspended, revoked, expired, not-yet-active, or deactivated license cannot obtain a new grant.

## Configuration

```swift
LicenseSeatStore.shared.configure(
    apiKey: "pk_live_…",
    productSlug: "my-product"
) { config in
    config.offlineFallbackMode = .networkOnly
    config.offlineTokenRefreshInterval = 72 * 60 * 60
    config.maxOfflineDays = 7
    config.maxClockSkewMs = 5 * 60 * 1_000
}
```

`networkOnly` is the production default. It allows fallback for transport failures, timeouts, and 5xx responses. An ordinary 401/403/404 request or scope error does not trigger fallback and does not erase a valid cache. Authoritative license-state responses—revoked, suspended, expired, not active, license not found, or device not activated—always invalidate cached grants.

`always` requests fallback for other nonterminal failures. It does not override authoritative license invalidation.

`maxOfflineDays` applies an optional application-side cap measured from the token's signed `iat` claim. Set it to `0` to disable this additional cap. The signed token `exp` and underlying `license_expires_at` are always enforced.

Intervals that are zero, negative, non-finite, or too large for the scheduler disable their corresponding timer safely.

## Manual Synchronization and Verification

Pre-fetch a fresh token before an expected outage:

```swift
await LicenseSeat.shared.syncOfflineAssets()
```

Verify the currently cached token:

```swift
let result = await LicenseSeat.shared.verifyCachedOffline()
guard result.valid else {
    print(result.code ?? "offline_validation_failed")
    return
}
```

`verifyCachedOffline()` may fetch a missing public key while online. Launch-time quick verification uses the same claim-validation implementation but never performs a network request.

During automatic fallback, a successful result updates the cached validation and exposes `LicenseStatus.offlineValid`. A later successful online validation clears the offline state.

## Security Invariants

Both quick and full verification enforce the same checks:

- `signature.algorithm` is Ed25519.
- `signature.key_id` equals the signed token `kid`.
- The decoded sibling `token` exactly matches the signed `canonical` JSON.
- The Ed25519 signature is valid for that canonical payload.
- `schema_version` is supported.
- The signed license key equals the protected cached activation.
- The signed product slug equals the configured product.
- A fingerprint is present and equals the activated fingerprint.
- `iat`, `nbf`, and `exp` form a valid time window.
- The token is not expired or not-yet-valid.
- The underlying license expiry has not passed.
- The optional maximum offline age from signed `iat` has not passed.
- The local clock has not moved backward beyond `maxClockSkewMs`.

The SDK verifies a newly downloaded token before it can replace the previous cache. A malformed or mismatched server response therefore cannot poison working offline recovery.

An online `valid: false` response removes the old offline token before persisting the invalid state. This prevents a relaunch from resurrecting a license that the server already rejected. Entitlement checks also require the top-level validation result to be valid, even if an inconsistent payload contains entitlement objects.

## Protected Storage

On platforms with Security.framework, LicenseSeat uses generic-password Keychain items with `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` for:

- the activated license and validation state;
- the signed offline token;
- cached Ed25519 public keys;
- the last-seen clock timestamp.
- the default app-scoped installation identifier (stored separately from the grant cache).

The storage prefix scopes Keychain account names. Existing 0.4.x UserDefaults and Application Support license files are migrated lazily. Plaintext is deleted only after the Keychain write succeeds, so an interrupted migration does not lose an activation.

On platforms without Security.framework, the SDK retains its UserDefaults fallback because Keychain is unavailable.

## Events

Observe synchronization and fallback with the canonical event names:

```swift
let ready = LicenseSeat.shared.on("offlineToken:ready") { payload in
    print("Offline grant ready: \(payload)")
}

let offline = LicenseSeat.shared.on("validation:offline-success") { _ in
    showOfflineBanner()
}
```

Relevant events include:

- `offlineToken:fetching`, `offlineToken:fetched`, `offlineToken:fetchError`
- `offlineToken:verified`, `offlineToken:verificationFailed`, `offlineToken:ready`
- `validation:offline-success`, `validation:offline-failed`
- `license:revoked`

Keep the returned cancellables alive for as long as the observation is needed.

## Failure Codes

Offline `ValidationResponse.code` values are stable machine-readable diagnostics:

- `no_offline_token`, `no_public_key`
- `signature_metadata_mismatch`, `signature_invalid`
- `token_payload_mismatch`, `unsupported_schema`
- `license_mismatch`, `product_mismatch`
- `fingerprint_missing`, `fingerprint_mismatch`
- `token_expired`, `token_not_yet_valid`, `invalid_time_window`
- `license_expired`, `grace_period_expired`
- `clock_tamper`, `cache_error`, `verification_error`

Treat any code other than a valid result as unlicensed. Do not add a permissive local bypass around these checks.

## Operational Guidance

- Activate and complete at least one successful offline-asset sync before testing an outage.
- Keep `.networkOnly` unless a deliberate compatibility requirement justifies `.always`.
- Set `maxOfflineDays` to the product's outage tolerance; it can be shorter than the server token TTL.
- Rotate Ed25519 keys by issuing a new unique key ID. Do not reuse a key ID for different key material.
- On logout, account switching, or license removal, call `deactivate()` or `purgeCachedLicense()` so protected grants do not cross identities.
