# Migrating from JavaScript

Map a LicenseSeat JavaScript integration to the native Swift lifecycle and security model.

## Configuration

JavaScript configuration objects become ``LicenseSeatConfig`` values or the static convenience API:

```swift
LicenseSeat.configure(
    apiKey: "pk_live_…",
    productSlug: "my-product"
) { config in
    config.autoValidateInterval = 3_600
    config.heartbeatInterval = 300
    config.offlineFallbackMode = .networkOnly
}
```

The production base URL is `https://licenseseat.com/api/v1`. Do not carry forward the obsolete `api.licenseseat.com` hostname or an `/api` path without `/v1`.

Embed only a publishable key. Environment variables and build settings make configuration convenient but do not make a client-embedded secret key confidential.

## Async Operations

JavaScript promises map directly to Swift `async throws`:

```swift
do {
    let license = try await LicenseSeat.activate(
        "CUSTOMER-KEY",
        options: ActivationOptions(
            deviceId: "stable-installation-fingerprint",
            deviceName: "Studio Mac",
            metadata: ["channel": "direct"]
        )
    )
    print(license.activationId)
} catch let error as APIError {
    print(error.code ?? "unknown", error.message)
}
```

The Swift property is `deviceId`; the canonical HTTP field emitted by the SDK is `fingerprint`. `device_id` and `device_fingerprint` remain server compatibility aliases but should not be used by new native integrations.

## Validation

```swift
let result = try await LicenseSeat.shared.validate(
    licenseKey: "CUSTOMER-KEY",
    options: ValidationOptions(deviceId: "stable-installation-fingerprint")
)

guard result.valid else {
    throw LicensingError.denied(result.code)
}
```

Usually omit `ValidationOptions.deviceId`; the SDK reuses the fingerprint stored with the activation. Supplying a different value intentionally asks the server to validate a different installation.

## Status and Entitlements

Replace loosely typed JavaScript state checks with exhaustive Swift enums:

```swift
switch LicenseSeat.shared.getStatus() {
case .active, .offlineValid:
    showApplication()
case .inactive, .pending, .invalid, .offlineInvalid:
    showLicensingUI()
}

if LicenseSeat.entitlement("export").active {
    enableExport()
}
```

Do not infer access from a non-nil entitlement. Use ``EntitlementStatus/active`` so invalid parent validation and entitlement expiry are enforced.

## Events

JavaScript event listeners map to closure subscriptions or Combine:

```swift
let subscription = LicenseSeat.shared.on("license:revoked") { payload in
    lockPremiumFeatures()
}

LicenseSeat.statusPublisher
    .sink { status in updateUI(status) }
    .store(in: &cancellables)
```

Retain closure cancellables. Combine cancellables should live with the observing object.

## Offline Storage and Verification

Do not port JavaScript local-storage code. The Swift SDK owns its cache:

- Apple platforms use Keychain with `AfterFirstUnlockThisDeviceOnly`;
- older 0.4.x UserDefaults and Application Support values migrate after a successful protected write;
- supported non-Apple platforms use UserDefaults as the portability fallback;
- the SDK verifies Ed25519 signature metadata, canonical token equality, license, product, fingerprint, time claims, license expiry, offline age, and clock rollback.

Call the public refresh API only when an immediate sync is useful:

```swift
await LicenseSeat.shared.syncOfflineAssets()
let offline = await LicenseSeat.shared.verifyCachedOffline()
```

`verifyCachedOffline()` fails closed when a token, key, activation, identity claim, signature, or required time claim is absent or invalid.

## Error Mapping

JavaScript response-code branching becomes ``APIError`` classification:

```swift
do {
    _ = try await LicenseSeat.activate("KEY")
} catch let error as APIError where error.isAuthError {
    showConfigurationError(error.message)
} catch let error as APIError where error.isRetryable {
    showTemporaryFailure(error.message)
} catch let error as APIError {
    showLicenseFailure(code: error.code, message: error.message)
}
```

The SDK parses both the standard `{ "error": … }` envelope and the JSON:API-style `errors` array used by machine-file endpoints.

## Deactivation and Cleanup

```swift
try await LicenseSeat.deactivate()
```

Deactivation releases the server seat and clears local activation and offline-token state. A terminal “already deactivated,” missing, or gone response is treated as idempotent success. Authentication or scope failures remain errors because the server outcome is not known.

Use `purgeCachedLicense()` only when intentionally removing local grants without releasing a server seat.

## Migration Checklist

1. Pin version 0.4.2 or newer.
2. Configure a publishable key and product slug.
3. Remove obsolete API hostnames and field names.
4. Delete application-owned plaintext license caches.
5. Gate access from `.active`, `.offlineValid`, and `EntitlementStatus.active`.
6. Preserve cancellables for event subscriptions.
7. Test activation, relaunch, online validation, signed offline fallback, expiry, suspension, deactivation, 403 scope failure, and recovery after an outage.
8. Review <doc:SecurityFeatures> and <doc:OfflineValidation> before release.
