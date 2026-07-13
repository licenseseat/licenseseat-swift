# Security Features

Understand the guarantees LicenseSeat provides, the trust boundaries it cannot remove, and the production configuration expected of a native client.

## Threat Model

The SDK protects cached license data from casual local modification and verifies that offline claims were issued by LicenseSeat. A determined user controls their own device, process, debugger, and filesystem; no client-only licensing system can make application code or a client-embedded credential secret from that user.

Design high-value server-side capabilities so the server re-authorizes them. Use the SDK to gate local product features and provide resilient UX, not as a replacement for server authorization.

## Publishable and Secret API Keys

Embed only a LicenseSeat publishable key (`pk_…`) in an application. The backend limits that key to client-safe scopes such as activation, validation, heartbeat, offline-token retrieval, and release reads.

Never ship a secret key (`sk_…`) in a native app. Secret keys can perform administrative operations and cannot be hidden by obfuscation, Keychain, environment variables, or build settings once distributed.

```swift
LicenseSeatStore.shared.configure(
    apiKey: "pk_live_…",
    productSlug: "my-product"
)
```

## Transport Security

The SDK accepts HTTPS API base URLs. Plain HTTP is rejected unless the host is a loopback development address (`localhost`, `127.0.0.1`, or `::1`). URLs containing credentials, queries, or fragments are rejected as invalid base URLs.

```swift
let config = LicenseSeatConfig(
    apiBaseUrl: "https://licenseseat.com/api/v1",
    apiKey: "pk_live_…",
    productSlug: "my-product"
)
```

The SDK relies on URLSession's platform trust evaluation. Certificate pinning is intentionally not built in: pinning adds an operational key-rotation requirement and should be introduced only with a documented backup-pin and emergency-rotation process.

## Device Binding

Activation sends one canonical `fingerprint` to the server. The same value is used for validation, heartbeat, deactivation, and offline-token issuance.

```swift
let license = try await LicenseSeat.shared.activate(
    licenseKey: "LICENSE-KEY",
    options: ActivationOptions(
        deviceId: "stable-custom-fingerprint",
        deviceName: "Studio Mac"
    )
)
```

When no custom value is supplied, `DeviceIdentifier` creates a random app-scoped installation identifier. Apple platforms protect it in Keychain and migrate the identifier created by older SDKs without changing the active seat. The default does not derive identity from a hardware serial, locale, screen, or other mutable device characteristic. A custom identifier must remain stable across launches and must not contain user-entered license data.

The offline verifier requires the signed token fingerprint to match the fingerprint in the protected cached activation. It also requires the signed license key and product slug to match local configuration.

## Offline Cryptography

Offline tokens use Ed25519 signatures. Apple platforms use CryptoKit; platforms without CryptoKit use SwiftCrypto.

Verification is fail-closed and checks:

- algorithm and key-ID consistency;
- equality between the signed canonical payload and the sibling token object;
- the Ed25519 signature;
- schema, license, product, and fingerprint identity;
- `iat`, `nbf`, token expiry, and underlying license expiry;
- optional maximum offline age measured from signed `iat`;
- local clock rollback.

Both launch-time quick verification and explicit/fallback verification call the same implementation. See <doc:OfflineValidation> for the full lifecycle.

Public signing keys are selected by the signed key ID. Key rotation must use a new key ID; do not publish different key material under an existing ID.

## Protected Cache

On Apple platforms, the SDK stores the following as generic-password Keychain items using `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`:

- activated license and latest validation;
- offline token;
- Ed25519 verification keys;
- last-seen clock timestamp.
- default app-scoped installation identifier (stored separately from revocable grant state).

This accessibility class supports background validation after the user has unlocked the device once and prevents the items from migrating to another device through a backup.

Older plaintext UserDefaults/Application Support data is migrated only after a successful Keychain write. Reset, purge, and deactivation remove the relevant protected grants.

On platforms where Security.framework is unavailable, UserDefaults remains the portability fallback. Applications with a platform-native secret store can place additional protection around the process, but must not skip SDK signature and identity verification.

## Authoritative Invalidation

Not every 4xx response means a license is invalid. A missing API scope or malformed request must not erase an otherwise valid signed grant.

The SDK purges cached grants only for authoritative terminal decisions such as license not found, revoked, suspended, expired, not active, device not activated, activation not found, or HTTP 410. It applies that policy consistently to validation, heartbeat, and offline refresh.

An HTTP 200 validation with `valid: false` retains the invalid response for UI diagnostics but removes the old offline token. Entitlements require `valid == true`; an inconsistent invalid payload cannot grant features.

## Clock Handling

`maxClockSkewMs` tolerates small clock differences for not-before and rollback checks. `maxOfflineDays` is measured from the signed `iat` claim, so editing a local timestamp cannot create a sliding grace period.

```swift
let config = LicenseSeatConfig(
    maxOfflineDays: 7,
    maxClockSkewMs: 300_000
)
```

Token and underlying license expiry are enforced even when `maxOfflineDays` is zero.

## Application Guidance

- Treat `.active` and `.offlineValid` as the only licensed statuses.
- Check `EntitlementStatus.active`, not merely whether an entitlement object exists.
- Call `deactivate()` when moving a seat and `purgeCachedLicense()` when local identity is removed without a server call.
- Keep the default `.networkOnly` fallback unless product requirements explicitly justify `.always`.
- Do not add local “temporary unlock” flags that bypass failed signature, identity, or expiry checks.
- Re-authorize server-side actions on the server.
- Test revoked, suspended, expired, scope-error, outage, relaunch, clock-rollback, and Keychain-migration paths before release.

## Reporting Security Issues

Send suspected vulnerabilities privately to security@licenseseat.com with reproduction steps, impact, and affected versions. Do not include live API keys, signing seeds, license keys, or customer data.
