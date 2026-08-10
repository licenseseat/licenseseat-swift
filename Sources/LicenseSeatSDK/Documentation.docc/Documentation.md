# ``LicenseSeat``

Integrate LicenseSeat activation, validation, entitlements, heartbeat, and signed offline grants into Swift applications.

## Overview

LicenseSeat is a main-actor-isolated SDK for macOS, iOS, tvOS, watchOS, and supported Swift platforms. Configure it with a client-safe publishable key and product slug, then activate the customer's license.

```swift
import LicenseSeat

LicenseSeat.configure(
    apiKey: "pk_live_…",
    productSlug: "my-product"
)

let license = try await LicenseSeat.activate("CUSTOMER-LICENSE-KEY")
```

The SDK persists the activation, validates it automatically, sends licensing heartbeats and optional device telemetry, downloads an Ed25519-signed offline token, and exposes entitlement state. On Apple platforms, licensing grants and verification keys are stored in Keychain.

Use either the static API or ``LicenseSeatStore``. Both configuration entry points now install the same process-wide ``LicenseSeat/shared`` instance, so Combine and SwiftUI observers cannot diverge from imperative calls.

## Topics

### Start Here

- <doc:GettingStarted>
- ``LicenseSeatConfig``
- ``LicenseSeatStore``

### License Lifecycle

- ``License``
- ``ActivationOptions``
- ``ValidationOptions``
- ``ValidationResponse``
- ``LicenseStatus``
- ``LicenseStatusDetails``
- ``LicenseSeatError``
- ``APIError``

### Entitlements and Reactive UI

- ``Entitlement``
- ``EntitlementStatus``
- ``EntitlementInactiveReason``
- <doc:ReactiveIntegration>
- <doc:LicenseSeatStore>
- <doc:EventReference>

### Resilience and Security

- <doc:OfflineValidation>
- <doc:NetworkResilience>
- <doc:SecurityFeatures>
- <doc:Privacy>

### Migration

- <doc:MigratingFromJavaScript>
