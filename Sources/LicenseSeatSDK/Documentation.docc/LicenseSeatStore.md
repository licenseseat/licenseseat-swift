# LicenseSeatStore – Batteries-Included Facade

> *Progressive disclosure*: trivial task, trivial code – advanced task, still possible.

## Overview
`LicenseSeatStore` is a high-level, opinionated façade around ``LicenseSeat`` that delivers a **zero-boiler-plate** integration path:

1. Configure once at app launch.
2. Activate a seat.
3. Observe `@Published` properties from SwiftUI, Combine, or `Observable`.

Under the hood the store spins all the same secure machinery as the low-level client—automatic validation timers, offline fallback, clock-skew detection—while exposing a Swifty API tailored for modern SwiftUI codebases.

```swift
import LicenseSeatSDK

@main
struct MyApp: App {
    init() {
        // One-liner configuration 🚀
        LicenseSeatStore.shared.configure(apiKey: Environment.licensingKey)
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .licenseSeat()   // Inject store into the environment
        }
    }
}
```

## Property Wrappers

### @LicenseState

`@LicenseState` gives any view direct access to the current ``LicenseStatus``:

```swift
struct ContentView: View {
    @LicenseState private var status

    var body: some View {
        switch status {
        case .active:        MainAppView()
        case .inactive:      ActivationView()
        case .pending:       ProgressView("Validating…")
        case .invalid:       ErrorView()
        case .offlineValid:  MainAppView()        // Grace-period
        case .offlineInvalid:ErrorView()
        }
    }
}
```

### @EntitlementState

`@EntitlementState` provides reactive access to individual feature flags:

```swift
struct FeatureView: View {
    @EntitlementState("export-pdf") private var canExportPDF
    @EntitlementState("team-collaboration") private var hasTeamFeatures
    
    var body: some View {
        VStack {
            if canExportPDF {
                Button("Export PDF") { exportDocument() }
            }
            
            if $hasTeamFeatures.active {  // Use projected value for full status
                TeamPanel()
            } else if $hasTeamFeatures.reason == .expired {
                RenewalPrompt()
            }
        }
    }
}
```

Both wrappers are powered by Combine under the hood and automatically stay on the main actor.

## Background Validation

The store subscribes to the `"autovalidation:cycle"` event emitted by the core SDK and surfaces the next scheduled run via ``LicenseSeatStore/nextAutoValidationAt``. Use it to display subtle UI like *"Next check in 59 s"*:

```swift
Text(timerString(from: store.nextAutoValidationAt))
    .font(.caption)
    .foregroundStyle(.secondary)
```

## Pass-Through API

Need more control? The store forwards the most common operations directly to the underlying seat:

```swift
try await LicenseSeatStore.shared.deactivate()
let entitlement = LicenseSeatStore.shared.entitlement("pro-export")

// Generate support ticket info
let diagnostics = LicenseSeatStore.shared.debugReport()
print(diagnostics) // Redacted data safe to send
```

And, because the `seat` property is `internal`, power users can still keep a reference to the original ``LicenseSeat`` instance if they need advanced APIs like `validate()` with custom options.

## Comparison Table

|                        | LicenseSeatStore | LicenseSeat |
|------------------------|-----------------|-------------|
| Zero-config singleton  | ✅              | ➖          |
| SwiftUI property wrappers | ✅          | ➖          |
| Background validation  | ✅ (auto)       | manual      |
| Offline asset refresh  | ✅ (auto)       | manual      |
| Combine publishers     | ✅             | ✅          |
| Full customisation     | limited        | ✅          |

## Migration from v1

1. Replace manual instantiation:
   ```swift
   let licenseSeat = LicenseSeat(config: cfg)
   ```
   with a one-liner:
   ```swift
   LicenseSeatStore.shared.configure(apiKey:"…")
   ```
2. Swap `seat.statusPublisher` with `@LicenseState` where appropriate.
3. All low-level APIs remain valid and are **not** deprecated until v3.

## Further Reading

* <doc:GettingStarted> – original low-level tutorial
* <doc:ReactiveIntegration> – Combine patterns that apply equally to the store
* ``LicenseSeatStore`` – full symbol reference 