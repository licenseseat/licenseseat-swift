# LicenseSeatStore – Legacy SwiftUI Integration

> **Note**: This is the legacy integration pattern. For new projects, use the static `LicenseSeat` methods shown in <doc:GettingStarted>.

## Overview

`LicenseSeatStore` is a convenience singleton that predates the current static API design. It remains available for backwards compatibility and provides some SwiftUI-specific conveniences.

**For new projects, we recommend:**
```swift
// Modern approach - use static methods
LicenseSeat.configure(apiKey: "YOUR_API_KEY")
try await LicenseSeat.activate("LICENSE-KEY")
```

## Legacy Store Pattern

The store pattern wraps the core `LicenseSeat` instance:

```swift
import LicenseSeat

@main
struct MyApp: App {
    init() {
        // Legacy configuration
        LicenseSeatStore.shared.configure(apiKey: Environment.licensingKey)
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .licenseSeat()   // Inject store into environment
        }
    }
}
```

## Property Wrappers

The store provides SwiftUI property wrappers that work with both the legacy store and modern API:

### @LicenseState

```swift
struct ContentView: View {
    @LicenseState private var status  // Works with either approach
    
    var body: some View {
        switch status {
        case .active:         MainAppView()
        case .inactive:       ActivationView()
        case .pending:        ProgressView("Validating…")
        case .invalid:        ErrorView()
        case .offlineValid:   MainAppView()
        case .offlineInvalid: ErrorView()
        }
    }
}
```

### @EntitlementState

```swift
struct FeatureView: View {
    @EntitlementState("premium") private var hasPremium
    
    var body: some View {
        if hasPremium {
            PremiumFeatures()
        } else {
            UpgradePrompt()
        }
    }
}
```

## Modern Alternative

Instead of using the store, you can achieve the same results with the static API:

```swift
// Configure once
LicenseSeat.configure(apiKey: "YOUR_API_KEY")

// Use anywhere
class LicenseViewModel: ObservableObject {
    @Published var status: LicenseStatus = .inactive(message: "")
    
    init() {
        // Subscribe to status changes
        LicenseSeat.statusPublisher
            .receive(on: DispatchQueue.main)
            .assign(to: &$status)
    }
    
    func activate(_ key: String) async throws {
        try await LicenseSeat.activate(key)
    }
}
```

## API Comparison

| Feature | Modern (Recommended) | Legacy Store |
|---------|---------------------|--------------|
| Configure | `LicenseSeat.configure(apiKey:)` | `LicenseSeatStore.shared.configure(apiKey:)` |
| Activate | `LicenseSeat.activate(_:)` | `LicenseSeatStore.shared.activate(_:)` |
| Check Status | `LicenseSeat.shared.getStatus()` | `LicenseSeatStore.shared.status` |
| Entitlements | `LicenseSeat.shared.checkEntitlement(_:)` | `LicenseSeatStore.shared.entitlement(_:)` |
| Property Wrappers | ✅ Work with both | ✅ Work with both |

## Should You Use the Store?

**Use the modern static API if:**
- Starting a new project
- Want consistency with other Swift SDKs
- Prefer explicit over implicit

**Keep using the store if:**
- You have existing code using it
- You prefer the singleton pattern
- You want the convenience methods

Both approaches are fully supported and will continue to work. The property wrappers (`@LicenseState`, `@EntitlementState`) work seamlessly with either approach.

## Migration Path

To migrate from store to static API:

```swift
// Old
LicenseSeatStore.shared.configure(apiKey: key)
try await LicenseSeatStore.shared.activate(licenseKey)
let status = LicenseSeatStore.shared.status

// New
LicenseSeat.configure(apiKey: key)
try await LicenseSeat.activate(licenseKey)
let status = LicenseSeat.shared.getStatus()
```

The functionality is identical - only the calling convention changes.

## Further Reading

- <doc:GettingStarted> - Modern integration guide
- <doc:ReactiveIntegration> - SwiftUI patterns
- ``LicenseSeat`` - Core API reference 