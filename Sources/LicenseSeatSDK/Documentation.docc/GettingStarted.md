# Getting Started

Configure LicenseSeat, activate a customer license, and gate features from one canonical SDK instance.

## Installation

Add the package with Swift Package Manager:

```swift
dependencies: [
    .package(
        url: "https://github.com/licenseseat/licenseseat-swift.git",
        from: "0.4.2"
    )
]
```

Add the `LicenseSeat` product to the application target. The package requires Swift 5.10 and supports macOS 12, iOS 13, tvOS 13, and watchOS 8 or newer.

## Configure Once

Call configuration from the main actor during application startup. Embed only a publishable (`pk_…`) key; never distribute a secret (`sk_…`) key in a client.

```swift
import LicenseSeat

LicenseSeat.configure(
    apiKey: "pk_live_…",
    productSlug: "my-product"
)
```

The default endpoint is `https://licenseseat.com/api/v1`. Custom production endpoints must use HTTPS. Plain HTTP is accepted only for loopback development hosts.

Use a trailing configuration closure for policy changes:

```swift
LicenseSeat.configure(
    apiKey: "pk_live_…",
    productSlug: "my-product"
) { config in
    config.autoValidateInterval = 3_600
    config.heartbeatInterval = 300
    config.offlineFallbackMode = .networkOnly
    config.maxOfflineDays = 7
}
```

`maxOfflineDays` adds an application-side maximum age measured from the signed `iat` claim. Zero removes this extra cap; token expiry and the underlying license expiry are still enforced.

Set `autoValidateInterval` to zero or a negative value when the host application
owns the online-validation cadence. This disables both the launch-time online
request and the periodic validation task. It does not disable launch-time local
verification of a cached signed offline grant, heartbeat, or offline-token
refresh; configure those independent intervals separately when needed.

## Activate

```swift
do {
    let license = try await LicenseSeat.activate(
        "CUSTOMER-LICENSE-KEY",
        options: ActivationOptions(deviceName: "Studio Mac")
    )

    print(license.licenseKey)
    print(license.deviceId)
    print(license.activationId)
} catch let error as APIError {
    print("\(error.code ?? "unknown"): \(error.message)")
}
```

The SDK sends the canonical wire field `fingerprint`. Supply `ActivationOptions.deviceId` only when the application already owns a stable device identifier:

```swift
let options = ActivationOptions(
    deviceId: "stable-installation-fingerprint",
    deviceName: "Editing Workstation",
    metadata: ["channel": "direct"]
)

let license = try await LicenseSeat.activate("KEY", options: options)
```

A successful activation is immediately represented as `.active`; callers do not need to wait for the first validation timer.

## Read Status and Entitlements

```swift
switch LicenseSeat.shared.getStatus() {
case .active(let details):
    unlockFeatures(details.entitlements)
case .offlineValid(let details):
    unlockFeatures(details.entitlements)
    showOfflineIndicator()
case .inactive(let message),
     .pending(let message),
     .invalid(let message),
     .offlineInvalid(let message):
    lockFeatures(reason: message)
}

let export = LicenseSeat.entitlement("export")
if export.active {
    enableExport()
}
```

Entitlements are granted only when the top-level validation is valid. The presence of an entitlement object in an invalid server response never grants access.

## Validate and Heartbeat Explicitly

Automatic validation and heartbeat start after activation and after a cached activation is loaded. Applications can also trigger them:

```swift
let result = try await LicenseSeat.shared.validate(
    licenseKey: "CUSTOMER-LICENSE-KEY"
)

try await LicenseSeat.shared.heartbeat()
```

`heartbeat()` throws ``LicenseSeatError/noActiveLicense`` when there is no current activation.

## Deactivate or Purge

Use deactivation when the server should release the seat:

```swift
try await LicenseSeat.deactivate()
```

Use ``LicenseSeat/purgeCachedLicense()`` only when local state must be removed without a server call, such as destructive account cleanup after a separate server workflow.

```swift
LicenseSeat.shared.purgeCachedLicense()
```

## SwiftUI

The observable store and static API share one underlying instance:

```swift
@main
struct MyApp: App {
    init() {
        LicenseSeatStore.shared.configure(
            apiKey: "pk_live_…",
            productSlug: "my-product"
        )
    }

    var body: some Scene {
        WindowGroup { ContentView() }
    }
}

struct ContentView: View {
    @LicenseState private var status
    @EntitlementState("export") private var canExport

    var body: some View {
        switch status {
        case .active, .offlineValid:
            MainView(canExport: canExport)
        default:
            ActivationView()
        }
    }
}
```

See <doc:ReactiveIntegration> and <doc:LicenseSeatStore> for Combine and SwiftUI details.

## Offline Readiness

After activation, the SDK downloads a signed offline token and its public verification key in the background. To request an immediate refresh:

```swift
await LicenseSeat.shared.syncOfflineAssets()
```

The downloaded token is verified before it can replace the cached grant. Network and eligible server failures fall back according to ``LicenseSeatConfig/OfflineFallbackMode``. Authoritative revoked, suspended, expired, inactive, or missing-license decisions purge stale grants instead of falling back.

See <doc:OfflineValidation> and <doc:SecurityFeatures> before changing offline policy.

## Error Handling

```swift
do {
    _ = try await LicenseSeat.activate("KEY")
} catch let error as APIError {
    switch error.code?.lowercased() {
    case "seat_limit_exceeded":
        showSeatManagement()
    case "revoked", "suspended", "expired":
        lockFeatures(reason: error.message)
    default:
        showError(error.message)
    }
} catch let error as LicenseSeatError {
    showError(error.localizedDescription)
}
```

Use error codes for program logic and messages for display. Authentication, scope, rate-limit, and malformed-request errors do not by themselves erase a valid cached grant.
