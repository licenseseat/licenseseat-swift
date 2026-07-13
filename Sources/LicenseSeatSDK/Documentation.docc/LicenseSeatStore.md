# LicenseSeatStore

Use the observable façade for SwiftUI while sharing state with the static LicenseSeat API.

## One Source of Truth

``LicenseSeatStore/shared`` and ``LicenseSeat/shared`` refer to the same configured SDK instance. Configuring either supported singleton entry point updates the other:

```swift
LicenseSeatStore.shared.configure(
    apiKey: "pk_live_…",
    productSlug: "my-product"
)

precondition(LicenseSeatStore.shared.status == LicenseSeat.shared.getStatus())
```

The first configuration call wins unless `force: true` is supplied. Forced reconfiguration shuts down the previous instance's initialization, validation, heartbeat, offline-refresh, connectivity, and event-subscription work before binding the replacement. Protected activation data is retained for the replacement when the storage prefix is unchanged.

## SwiftUI Setup

```swift
@main
struct MyApp: App {
    init() {
        LicenseSeatStore.shared.configure(
            apiKey: AppConfiguration.publishableKey,
            productSlug: "my-product"
        )
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .licenseSeat()
        }
    }
}
```

The environment injection is optional for the supplied property wrappers because they observe the shared store directly.

## Observable Status

```swift
struct ContentView: View {
    @LicenseState private var status

    var body: some View {
        switch status {
        case .active, .offlineValid:
            MainView()
        case .pending:
            ProgressView("Validating…")
        default:
            ActivationView()
        }
    }
}
```

Feature gates can use ``EntitlementState``:

```swift
struct ExportButton: View {
    @EntitlementState("export") private var canExport

    var body: some View {
        Button("Export", action: export)
            .disabled(!canExport)
    }
}
```

## Imperative Operations

```swift
let store = LicenseSeatStore.shared

let license = try await store.activate("CUSTOMER-KEY")
let validation = try await store.validate(licenseKey: license.licenseKey)
let export = store.entitlement("export")
try await store.heartbeat()
try await store.deactivate()
store.reset()
```

Activation, validation, deactivation, and reset update the published status
before returning; callers do not have to wait for a later Combine run-loop
delivery.

## Detached Stores

Create a detached store for dependency injection or tests:

```swift
var config = LicenseSeatConfig(
    apiKey: "pk_test_…",
    productSlug: "test-product",
    autoValidateInterval: 0,
    heartbeatInterval: 0
)

let store = LicenseSeatStore(config: config, urlSession: testSession)
```

A detached store does not replace the process-wide singleton.
An `autoValidateInterval` of zero disables both launch-time and periodic online
validation, which lets a host or test own the online cadence without disabling
local signed-cache verification.

## Diagnostics

``LicenseSeatStore/debugReport()`` returns status, SDK version, timestamps, a license-key prefix, and a stable truncated SHA-256 fingerprint digest. It does not return the full license key or device fingerprint. Review support reports before transmitting them because timestamps and status can still be customer metadata.

See <doc:ReactiveIntegration> for publisher-based integrations.
