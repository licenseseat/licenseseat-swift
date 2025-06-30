# LicenseSeat for Swift

[![Swift](https://img.shields.io/badge/Swift-5.8+-orange.svg)](https://swift.org)
[![Platforms](https://img.shields.io/badge/Platforms-macOS%20|%20iOS%20|%20tvOS%20|%20watchOS%20|%20Linux-blue.svg)](https://swift.org)
[![License](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE.txt)
[![CI](https://github.com/licenseseat/licenseseat-swift/actions/workflows/ci.yml/badge.svg)](https://github.com/licenseseat/licenseseat-swift/actions/workflows/ci.yml)
[![Documentation](https://img.shields.io/badge/docs-DocC-blue.svg)](https://licenseseat.github.io/licenseseat-swift/documentation/licenseseat/)

A comprehensive Swift SDK for managing software licenses with the [LicenseSeat](https://licenseseat.com) licensing system.

## Features

- 🔐 **License Activation & Deactivation** - Simple async/await APIs for license lifecycle
- ✅ **Online & Offline Validation** - Ed25519 cryptographic verification for offline use
- 🔄 **Automatic Re-validation** - Background validation with configurable intervals
- 🎯 **Entitlement Management** - Fine-grained feature access control
- 🌐 **Network Resilience** - Automatic retry with exponential backoff
- 📡 **Event-Driven Architecture** - Combine publishers and callbacks for reactive UIs
- 🔒 **Security Features** - Clock tamper detection and secure caching
- 📱 **Multi-Platform** - Full support for Apple platforms and Linux

## Installation

### Swift Package Manager

Add to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/licenseseat/licenseseat-swift.git", from: "1.0.0")
]
```

Or in Xcode:
1. File → Add Package Dependencies
2. Enter: `https://github.com/licenseseat/licenseseat-swift.git`

## Quick Start

### 🪄 *Magic* Integration (Recommended)

Add licensing to a brand-new SwiftUI app in **three lines**:

```swift
import LicenseSeat

// 1️⃣ Activate (e.g. after user enters their license)
try await LicenseSeat.shared.activate(licenseKey: "USER-LICENSE-KEY")

// 2️⃣ Observe anywhere in SwiftUI
struct ContentView: View {
    @LicenseState private var status               // instantly reactive ✨
    @EntitlementState("pro-features") private var hasPro   // feature flags

    var body: some View {
        switch status {
        case .active:        
            MainAppView(showProFeatures: hasPro)
        case .pending:       
            ProgressView("Validating…")
        case .inactive:      
            ActivationView()
        case .invalid:       
            ErrorView()
        case .offlineValid:  
            MainAppView(showProFeatures: hasPro)   // Grace-period
        case .offlineInvalid:
            ErrorView()
        }
    }
}
```

The `LicenseSeatStore` singleton handles:

* Secure persistence & keychain storage
* Background auto-validation based on `autoValidateInterval`
* Offline license refresh & public-key syncing
* Reactive `@Published` properties for SwiftUI / Combine

### Low-Level API (Power Users)

Prefer full control or a UIKit / CLI environment? You can still use the original `LicenseSeat` client directly:

```swift
import LicenseSeat

let config = LicenseSeatConfig(
    apiBaseUrl: "https://api.licenseseat.com",
    apiKey: "YOUR_API_KEY"
)

let licenseSeat = LicenseSeat(config: config)

// Activate
let license = try await licenseSeat.activate(licenseKey: "USER-LICENSE-KEY")

// Validate on demand
let result = try await licenseSeat.validate(licenseKey: "USER-LICENSE-KEY")

// Real-time status via Combine
licenseSeat.statusPublisher
    .sink { print("Status changed: \($0)") }
    .store(in: &cancellables)
```

## Core Concepts

### License Lifecycle

```swift
// Activate
let license = try await licenseSeat.activate(
    licenseKey: "KEY",
    options: ActivationOptions(
        deviceIdentifier: nil, // Auto-generated if nil
        metadata: ["version": "1.0"]
    )
)

// Validate
let result = try await licenseSeat.validate(licenseKey: "KEY")

// Deactivate
try await licenseSeat.deactivate()

// Check status
switch licenseSeat.getStatus() {
case .active(let details):
    print("Active: \(details.license)")
case .offlineValid(let details):
    print("Valid offline: \(details.license)")
default:
    print("Not active")
}
```

### Entitlements

```swift
let entitlement = licenseSeat.checkEntitlement("feature-key")

if entitlement.active {
    enableFeature()
} else if entitlement.reason == .expired {
    showRenewalPrompt()
}

// Monitor changes
licenseSeat.entitlementPublisher(for: "feature-key")
    .sink { status in
        updateFeatureAccess(status.active)
    }
    .store(in: &cancellables)
```

### Offline Validation

The SDK automatically falls back to cryptographically-verified offline validation when the network is unavailable:

```swift
// Configure offline support
let config = LicenseSeatConfig(
    offlineFallbackEnabled: true,
    maxOfflineDays: 7,  // Grace period
    offlineLicenseRefreshInterval: 259200  // 72 hours
)

// Offline validation happens automatically
// Events notify you of the validation type:
licenseSeat.on("validation:offline-success") { _ in
    print("Validated offline")
}
```

### Event System

Traditional callbacks:
```swift
let cancellable = licenseSeat.on("activation:success") { data in
    print("Activated!")
}

// Later...
licenseSeat.off("activation:success", handler: cancellable)
```

Combine publishers:
```swift
// All events
licenseSeat.eventPublisher
    .filter { $0.name.hasPrefix("validation:") }
    .sink { event in
        print("\(event.name): \(event.data)")
    }

// Specific publishers
licenseSeat.networkStatusPublisher
    .sink { isOnline in
        updateNetworkIndicator(isOnline)
    }
```

## Advanced Configuration

```swift
let config = LicenseSeatConfig(
    apiBaseUrl: "https://api.licenseseat.com",
    apiKey: "your-api-key",
    storagePrefix: "myapp_",              // Namespace for storage keys
    deviceIdentifier: nil,                // Custom device ID (auto if nil)
    autoValidateInterval: 3600,           // 1 hour
    networkRecheckInterval: 30,           // 30s when offline
    maxRetries: 3,                        // API retry attempts
    retryDelay: 1,                        // Base delay (exponential)
    debug: true,                          // Enable debug logging
    offlineLicenseRefreshInterval: 259200,// 72 hours
    offlineFallbackEnabled: true,         // Enable offline mode
    maxOfflineDays: 7,                    // Grace period
    maxClockSkewMs: 300000                // 5 minutes tolerance
)
```

## Platform Support

- **macOS 11+** - Full support including hardware UUID
- **iOS 14+** - Full support with Keychain integration
- **tvOS 14+** - Full support
- **watchOS 7+** - Limited (no Network framework)
- **Linux** - Core features (no CryptoKit offline validation)

## Security

- **Ed25519 Signatures** - Offline licenses are cryptographically signed
- **Clock Tamper Detection** - Detects system clock manipulation
- **Secure Storage** - License data stored in UserDefaults + file backup
- **Constant-Time Comparison** - Prevents timing attacks
- **No Network Requirement** - Fully functional offline after initial activation

## Testing

The SDK includes comprehensive test coverage:

```bash
swift test

# With coverage
swift test --enable-code-coverage
```

## Example CLI (Interactive Test App)

Explore the SDK without writing any code by running the bundled command-line application.

```bash
# From the repository root
swift run --package-path Examples/LicenseSeatExample

# Or, if you prefer to change directories first
cd Examples/LicenseSeatExample
swift run
```

The program presents a menu that lets you:

1. Activate a license
2. Validate it (online / offline)
3. Check entitlements
4. Show current cached status
5. Deactivate
6. Test API-key authentication
7. Reset all persisted data

Each action prints its result, then waits for you to press **Enter** before clearing the screen so the next menu is always clean.

### Pointing the CLI at a local server

Running your own LicenseSeat backend on `http://localhost:3000`?  Export two environment variables before launching:

```bash
export LICENSESEAT_API_URL=http://localhost:3000   # Base URL for all API calls
export LICENSESEAT_API_KEY=sk_test_123             # Only if your endpoints require it
swift run --package-path Examples/LicenseSeatExample
```

All SDK network requests will now hit your local instance instead of the public cloud API.

## Documentation

Full API documentation is available at [https://licenseseat.github.io/licenseseat-swift](https://licenseseat.github.io/licenseseat-swift/documentation/licenseseat/)

Or build locally:
```bash
swift package generate-documentation
```

## Migration from JavaScript SDK

This Swift SDK provides 100% feature parity with the official JavaScript SDK. The API follows Swift conventions while maintaining conceptual compatibility:

| JavaScript | Swift |
|------------|-------|
| `new LicenseSeat(config)` | `LicenseSeat(config:)` |
| `sdk.activate(key, options)` | `sdk.activate(licenseKey:options:)` |
| `sdk.on('event', callback)` | `sdk.on("event") { }` or publishers |
| `sdk.getStatus()` | `sdk.getStatus()` returns enum |

## Contributing

We welcome contributions! Please see [CONTRIBUTING.md](CONTRIBUTING.md) for guidelines.

## License

This SDK is released under the MIT License. See [LICENSE.txt](LICENSE.txt) for details.

## Support

- 📧 Email: support@licenseseat.com
- 💬 Discord: [Join our community](https://discord.gg/licenseseat)
- 📖 Docs: [https://docs.licenseseat.com](https://docs.licenseseat.com) 