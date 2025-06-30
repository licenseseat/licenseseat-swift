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

## 🚀 The Two-Minute Integration

```swift
import LicenseSeat

// 1️⃣ Configure once at app launch
LicenseSeat.configure(apiKey: "YOUR_API_KEY")

// 2️⃣ Activate when user enters license
try await LicenseSeat.activate("USER-LICENSE-KEY")

// 3️⃣ Check status anywhere
if case .active = LicenseSeat.shared.getStatus() {
    // License is valid - enable features
}
```

## SwiftUI Integration (Recommended)

For reactive SwiftUI apps, use the built-in property wrappers:

```swift
import LicenseSeat
import SwiftUI

// Configure at app startup
@main
struct MyApp: App {
    init() {
        LicenseSeat.configure(apiKey: ProcessInfo.processInfo.environment["LICENSESEAT_API_KEY"] ?? "")
    }
    
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

// Use reactive property wrappers in any view
struct ContentView: View {
    @LicenseState private var status                        // Auto-updates on status changes
    @EntitlementState("pro-features") private var hasPro    // Feature flags
    
    var body: some View {
        switch status {
        case .active:
            MainAppView()
                .environment(\.proFeaturesEnabled, hasPro)
                
        case .inactive:
            LicenseActivationView()
            
        case .invalid(let message):
            ErrorView(message: message)
            
        case .pending:
            ProgressView("Validating license...")
            
        case .offlineValid:
            MainAppView()
                .environment(\.proFeaturesEnabled, hasPro)
                .overlay(alignment: .top) {
                    OfflineModeBanner()
                }
                
        case .offlineInvalid:
            ExpiredLicenseView()
        }
    }
}

// Simple activation flow
struct LicenseActivationView: View {
    @State private var licenseKey = ""
    @State private var isLoading = false
    @State private var error: String?
    
    var body: some View {
        Form {
            TextField("License Key", text: $licenseKey)
                .textFieldStyle(.roundedBorder)
            
            Button("Activate") {
                Task {
                    isLoading = true
                    defer { isLoading = false }
                    
                    do {
                        try await LicenseSeat.activate(licenseKey)
                    } catch {
                        self.error = error.localizedDescription
                    }
                }
            }
            .disabled(licenseKey.isEmpty || isLoading)
            
            if let error {
                Text(error)
                    .foregroundColor(.red)
                    .font(.caption)
            }
        }
        .padding()
    }
}

## UIKit / AppKit Integration

For traditional UI frameworks:

```swift
import LicenseSeat
import Combine

class LicenseManager: ObservableObject {
    private var cancellables = Set<AnyCancellable>()
    @Published var isLicensed = false
    @Published var hasProFeatures = false
    
    init() {
        // Configure the SDK
        LicenseSeat.configure(apiKey: Config.apiKey)
        
        // Subscribe to status changes
        LicenseSeat.statusPublisher
            .sink { [weak self] status in
                self?.isLicensed = status.isValid
            }
            .store(in: &cancellables)
            
        // Monitor specific entitlements
        LicenseSeat.shared.entitlementPublisher(for: "pro-features")
            .map { $0.active }
            .assign(to: &$hasProFeatures)
    }
    
    func activate(_ key: String) async throws {
        try await LicenseSeat.activate(key)
    }
    
    func deactivate() async throws {
        try await LicenseSeat.deactivate()
    }
}

## Advanced Usage (Full Control)

For complete control, use the instance API directly:

```swift
import LicenseSeat

// Create a custom configured instance
let config = LicenseSeatConfig(
    apiBaseUrl: "https://api.licenseseat.com",
    apiKey: "YOUR_API_KEY",
    autoValidateInterval: 3600,        // Validate every hour
    offlineFallbackEnabled: true,      // Enable offline validation
    maxOfflineDays: 7                  // 7-day grace period
)

let licenseSeat = LicenseSeat(config: config)

// Full lifecycle control
let license = try await licenseSeat.activate(
    licenseKey: "USER-KEY",
    options: ActivationOptions(
        deviceIdentifier: "custom-device-id",
        metadata: ["version": "1.0.0"]
    )
)

// Manual validation
let validation = try await licenseSeat.validate(
    licenseKey: license.licenseKey,
    options: ValidationOptions(productSlug: "pro-edition")
)

// Check entitlements
let exportFeature = licenseSeat.checkEntitlement("export-pdf")
if exportFeature.active {
    enablePDFExport()
}
```

### The Store Pattern (Legacy, but still supported)

The `LicenseSeatStore` singleton is maintained for backwards compatibility:

```swift
// Legacy API - still works but not recommended for new projects
LicenseSeatStore.shared.configure(apiKey: "YOUR_API_KEY")
try await LicenseSeatStore.shared.activate("LICENSE-KEY")
```

We recommend using the static `LicenseSeat` methods instead, as shown above.

## Core Concepts

### License Lifecycle

```swift
// Configure SDK (once at app startup)
LicenseSeat.configure(apiKey: "YOUR_API_KEY")

// Activate a license
let license = try await LicenseSeat.activate(
    "USER-LICENSE-KEY",
    options: ActivationOptions(
        deviceIdentifier: nil,      // Auto-generated if nil
        metadata: ["version": "1.0.0", "environment": "production"]
    )
)

// Check current status
switch LicenseSeat.shared.getStatus() {
case .active(let details):
    print("Licensed to: \(details.license)")
    print("Device: \(details.device)")
    
case .offlineValid(let details):
    print("Valid offline until next sync")
    print("Activated: \(details.activatedAt)")
    
case .inactive:
    print("No license activated")
    
case .invalid(let message):
    print("License invalid: \(message)")
    
case .pending:
    print("Validation in progress...")
    
case .offlineInvalid:
    print("License expired (offline)")
}

// Deactivate when needed
try await LicenseSeat.deactivate()
```

### Entitlements

Control feature access based on license entitlements:

```swift
// Check entitlement synchronously
let entitlement = LicenseSeat.shared.checkEntitlement("premium-features")

switch entitlement.reason {
case nil where entitlement.active:
    enablePremiumFeatures()
    
case .expired:
    showRenewalPrompt(expiresAt: entitlement.expiresAt)
    
case .notFound:
    showUpgradePrompt()
    
case .noLicense:
    showActivationPrompt()
    
default:
    disablePremiumFeatures()
}

// React to entitlement changes
LicenseSeat.shared.entitlementPublisher(for: "api-access")
    .receive(on: DispatchQueue.main)
    .sink { status in
        apiAccessEnabled = status.active
        if let expiresAt = status.expiresAt {
            scheduleExpirationWarning(at: expiresAt)
        }
    }
    .store(in: &cancellables)

// Check multiple entitlements
let features = [
    "export-pdf": LicenseSeat.shared.checkEntitlement("export-pdf"),
    "advanced-analytics": LicenseSeat.shared.checkEntitlement("advanced-analytics"),
    "team-collaboration": LicenseSeat.shared.checkEntitlement("team-collaboration")
]

let activeFeatures = features.compactMap { $0.value.active ? $0.key : nil }
```

### Offline Validation

The SDK provides seamless offline support with cryptographic validation:

```swift
// Configure with offline support
LicenseSeat.configure(apiKey: "YOUR_API_KEY") { config in
    config.offlineFallbackEnabled = true
    config.maxOfflineDays = 7              // 7-day grace period
    config.offlineLicenseRefreshInterval = 259200  // Refresh every 72 hours
}

// Monitor online/offline transitions
LicenseSeat.shared.networkStatusPublisher
    .sink { isOnline in
        if isOnline {
            statusLabel.text = "Connected"
        } else {
            statusLabel.text = "Offline Mode"
        }
    }
    .store(in: &cancellables)

// Listen for offline validation events
LicenseSeat.shared.on("validation:offline-success") { result in
    print("Validated offline - valid until next online check")
}

LicenseSeat.shared.on("validation:offline-failed") { result in
    print("Offline validation failed - license may be expired")
}

// Force offline license sync
try await LicenseSeat.shared.syncOfflineAssets()
```

### Event System

The SDK provides comprehensive event tracking through callbacks and Combine publishers:

```swift
// Subscribe to events with callbacks
let cancellable = LicenseSeat.shared.on("activation:success") { license in
    print("License activated: \(license)")
    Analytics.track("license_activated")
}

// Unsubscribe when done
LicenseSeat.shared.off("activation:success", handler: cancellable)

// Or use Combine publishers for specific events
LicenseSeat.shared.eventPublisher
    .filter { $0.name.hasPrefix("validation:") }
    .sink { event in
        switch event.name {
        case "validation:success":
            updateLastValidatedLabel()
        case "validation:failed":
            if let result = event.data as? LicenseValidationResult {
                showValidationError(result.reason ?? "Unknown error")
            }
        case "validation:offline-success":
            showOfflineModeBanner()
        default:
            break
        }
    }
    .store(in: &cancellables)

// Specialized publishers for common use cases
LicenseSeat.shared.networkStatusPublisher
    .removeDuplicates()
    .sink { isOnline in
        networkIndicator.isHidden = isOnline
    }
    .store(in: &cancellables)

// Available events:
// - activation:start/success/error
// - validation:start/success/failed/error/offline-success/offline-failed
// - deactivation:start/success/error
// - network:online/offline
// - license:loaded
// - sdk:reset
```

## Advanced Configuration

```swift
// Configure with custom settings
LicenseSeat.configure(
    apiKey: "YOUR_API_KEY",
    apiBaseURL: URL(string: "https://api.licenseseat.com")!
) { config in
    // Namespace for storage keys (useful for multiple products)
    config.storagePrefix = "myapp_"
    
    // Custom device identifier (auto-generated if nil)
    config.deviceIdentifier = UIDevice.current.identifierForVendor?.uuidString
    
    // Validation intervals
    config.autoValidateInterval = 3600          // Re-validate every hour
    config.networkRecheckInterval = 30          // Check connectivity every 30s when offline
    
    // Network resilience
    config.maxRetries = 3                       // Retry failed requests 3 times
    config.retryDelay = 1                       // Base delay (exponential backoff)
    
    // Offline support
    config.offlineFallbackEnabled = true        // Enable offline validation
    config.offlineLicenseRefreshInterval = 259200  // Refresh keys every 72 hours
    config.maxOfflineDays = 7                   // Allow 7 days offline
    config.maxClockSkewMs = 300000              // 5 minutes clock tolerance
    
    // Development
    config.debug = true                         // Enable debug logging
}

// Or create a standalone instance with custom config
let customInstance = LicenseSeat(
    config: LicenseSeatConfig(
        apiKey: "YOUR_API_KEY",
        apiBaseUrl: "https://staging.licenseseat.com",
        debug: true
    )
)
```

### Environment-based Configuration

```swift
// Production setup
struct LicenseConfiguration {
    static func configure() {
        let apiKey = ProcessInfo.processInfo.environment["LICENSESEAT_API_KEY"] ?? ""
        let apiURL = ProcessInfo.processInfo.environment["LICENSESEAT_API_URL"]
            .flatMap(URL.init) ?? URL(string: "https://api.licenseseat.com")!
        
        #if DEBUG
        LicenseSeat.configure(apiKey: apiKey, apiBaseURL: apiURL) { config in
            config.debug = true
            config.autoValidateInterval = 60  // More frequent in debug
        }
        #else
        LicenseSeat.configure(apiKey: apiKey, apiBaseURL: apiURL) { config in
            config.debug = false
            config.autoValidateInterval = 3600
            config.offlineFallbackEnabled = true
            config.maxOfflineDays = 14  // Two weeks for production
        }
        #endif
    }
}
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