# LicenseSeat Swift SDK

[![Swift 5.9+](https://img.shields.io/badge/Swift-5.9+-F05138.svg?style=flat)](https://swift.org)
[![Platforms](https://img.shields.io/badge/Platforms-macOS%2012+%20|%20iOS%2013+%20|%20tvOS%2013+%20|%20watchOS%208+-blue.svg)](https://swift.org)
[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE.txt)
[![CI](https://github.com/licenseseat/licenseseat-swift/actions/workflows/ci.yml/badge.svg)](https://github.com/licenseseat/licenseseat-swift/actions/workflows/ci.yml)
[![Documentation](https://img.shields.io/badge/Docs-DocC-blue.svg)](https://licenseseat.github.io/licenseseat-swift/documentation/licenseseat/)

The official Swift SDK for [LicenseSeat](https://licenseseat.com) — the simple, secure licensing platform for apps, games, and plugins.

## Features

- **License Lifecycle** — Activate, validate, and deactivate licenses with async/await APIs
- **Offline Validation** — Ed25519 cryptographic verification for offline use with configurable grace periods
- **Automatic Re-validation** — Background validation with configurable intervals
- **Entitlement Management** — Fine-grained feature access control with expiration tracking
- **Network Resilience** — Automatic retry with exponential backoff and offline fallback
- **Reactive UI Support** — SwiftUI property wrappers and Combine publishers for reactive updates
- **Security Features** — Clock tamper detection, secure caching, and constant-time comparisons
- **Cross-Platform** — Full support for Apple platforms (macOS, iOS, tvOS, watchOS)

## Table of Contents

- [LicenseSeat Swift SDK](#licenseseat-swift-sdk)
  - [Features](#features)
  - [Table of Contents](#table-of-contents)
  - [Installation](#installation)
    - [Swift Package Manager](#swift-package-manager)
    - [Xcode](#xcode)
  - [Quick Start](#quick-start)
    - [1. Configure the SDK](#1-configure-the-sdk)
    - [2. Activate a License](#2-activate-a-license)
    - [3. Check License Status](#3-check-license-status)
    - [4. Deactivate](#4-deactivate)
  - [SwiftUI Integration](#swiftui-integration)
  - [UIKit / AppKit Integration](#uikit--appkit-integration)
  - [Advanced Usage](#advanced-usage)
    - [Custom Configuration](#custom-configuration)
    - [Manual Validation](#manual-validation)
  - [Configuration Options](#configuration-options)
    - [Environment-Based Configuration](#environment-based-configuration)
  - [Entitlements](#entitlements)
    - [Reactive Entitlement Monitoring](#reactive-entitlement-monitoring)
  - [Offline Validation](#offline-validation)
    - [Offline Fallback Modes](#offline-fallback-modes)
  - [Event System](#event-system)
    - [Available Events](#available-events)
  - [Platform Support](#platform-support)
  - [Example App](#example-app)
  - [Publishing \& Distribution](#publishing--distribution)
    - [For SDK Users](#for-sdk-users)
    - [For SDK Maintainers: Publishing a New Version](#for-sdk-maintainers-publishing-a-new-version)
    - [Version Requirements for Users](#version-requirements-for-users)
    - [CI/CD](#cicd)
  - [API Documentation](#api-documentation)
    - [Generate Documentation Locally](#generate-documentation-locally)
  - [Testing](#testing)
  - [Migration from JavaScript SDK](#migration-from-javascript-sdk)
  - [License](#license)
  - [Support](#support)

---

## Installation

### Swift Package Manager

Add LicenseSeat to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/licenseseat/licenseseat-swift.git", from: "0.2.0")
]
```

Then add the dependency to your target:

```swift
.target(
    name: "YourApp",
    dependencies: [
        .product(name: "LicenseSeat", package: "licenseseat-swift")
    ]
)
```

### Xcode

1. Open your project in Xcode
2. Go to **File → Add Package Dependencies**
3. Enter the repository URL: `https://github.com/licenseseat/licenseseat-swift.git`
4. Select your version requirements and add to your target

---

## Quick Start

### 1. Configure the SDK

Configure LicenseSeat once at app launch:

```swift
import LicenseSeat

// In your app's initialization (e.g., @main App.init or AppDelegate)
LicenseSeat.configure(apiKey: "YOUR_API_KEY")
```

### 2. Activate a License

When a user enters their license key:

```swift
do {
    let license = try await LicenseSeat.activate("USER-LICENSE-KEY")
    print("Activated: \(license.licenseKey)")
} catch {
    print("Activation failed: \(error.localizedDescription)")
}
```

### 3. Check License Status

```swift
switch LicenseSeat.shared.getStatus() {
case .active(let details):
    print("Licensed! Device: \(details.device)")
case .offlineValid(let details):
    print("Valid offline until next sync")
case .inactive:
    print("No license activated")
case .invalid(let message):
    print("Invalid: \(message)")
case .pending:
    print("Validating...")
case .offlineInvalid(let message):
    print("Offline validation failed: \(message)")
}
```

### 4. Deactivate

```swift
try await LicenseSeat.deactivate()
```

---

## SwiftUI Integration

LicenseSeat provides property wrappers for reactive SwiftUI apps:

```swift
import SwiftUI
import LicenseSeat

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

struct ContentView: View {
    @LicenseState private var status           // Auto-updates on license changes
    @EntitlementState("pro") private var hasPro // Feature flag

    var body: some View {
        switch status {
        case .active, .offlineValid:
            MainAppView()
                .environment(\.proEnabled, hasPro)
        case .inactive:
            ActivationView()
        case .invalid(let message):
            ErrorView(message: message)
        case .pending:
            ProgressView("Validating...")
        case .offlineInvalid:
            ExpiredView()
        }
    }
}

struct ActivationView: View {
    @State private var licenseKey = ""
    @State private var isLoading = false
    @State private var error: String?

    var body: some View {
        Form {
            TextField("License Key", text: $licenseKey)

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
                Text(error).foregroundColor(.red)
            }
        }
    }
}
```

---

## UIKit / AppKit Integration

Use Combine publishers for reactive updates in traditional UI frameworks:

```swift
import LicenseSeat
import Combine

class LicenseManager: ObservableObject {
    @Published var isLicensed = false
    @Published var hasProFeatures = false

    private var cancellables = Set<AnyCancellable>()

    init() {
        LicenseSeat.configure(apiKey: "YOUR_API_KEY")

        // React to license status changes
        LicenseSeat.statusPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in
                self?.isLicensed = status.isValid
            }
            .store(in: &cancellables)

        // Monitor specific entitlements
        LicenseSeat.shared.entitlementPublisher(for: "pro-features")
            .map { $0.active }
            .receive(on: DispatchQueue.main)
            .assign(to: &$hasProFeatures)
    }

    func activate(_ key: String) async throws {
        try await LicenseSeat.activate(key)
    }

    func deactivate() async throws {
        try await LicenseSeat.deactivate()
    }
}
```

---

## Advanced Usage

### Custom Configuration

For full control, create an instance with custom configuration:

```swift
let config = LicenseSeatConfig(
    apiKey: "YOUR_API_KEY",
    storagePrefix: "myapp_",
    autoValidateInterval: 3600,      // Re-validate every hour
    maxRetries: 3,
    retryDelay: 1,
    offlineFallbackEnabled: true,    // Enable offline validation
    maxOfflineDays: 7,               // 7-day grace period
    debug: true
)

let licenseSeat = LicenseSeat(config: config)

// Use instance methods
let license = try await licenseSeat.activate(
    licenseKey: "USER-KEY",
    options: ActivationOptions(
        deviceIdentifier: "custom-device-id",
        metadata: ["version": "2.0.0", "environment": "production"]
    )
)
```

### Manual Validation

```swift
let result = try await licenseSeat.validate(
    licenseKey: license.licenseKey,
    options: ValidationOptions(productSlug: "pro-edition")
)

if result.valid {
    print("License is valid")
    if result.offline {
        print("Validated offline")
    }
}
```

---

## Configuration Options

| Option                   | Type           | Default                       | Description                            |
| ------------------------ | -------------- | ----------------------------- | -------------------------------------- |
| `apiBaseUrl`             | `String`       | `https://licenseseat.com/api` | API endpoint                           |
| `apiKey`                 | `String?`      | `nil`                         | Your API key                           |
| `storagePrefix`          | `String`       | `licenseseat_`                | Prefix for cache keys                  |
| `deviceIdentifier`       | `String?`      | Auto-generated                | Custom device ID                       |
| `autoValidateInterval`   | `TimeInterval` | `3600` (1 hour)               | Background validation interval         |
| `networkRecheckInterval` | `TimeInterval` | `30`                          | Offline connectivity check interval    |
| `maxRetries`             | `Int`          | `3`                           | API retry attempts                     |
| `retryDelay`             | `TimeInterval` | `1`                           | Base retry delay (exponential backoff) |
| `offlineFallbackEnabled` | `Bool`         | `false`                       | Enable offline validation              |
| `maxOfflineDays`         | `Int`          | `0`                           | Grace period for offline use           |
| `maxClockSkewMs`         | `TimeInterval` | `300000` (5 min)              | Clock tamper tolerance                 |
| `debug`                  | `Bool`         | `false`                       | Enable debug logging                   |

### Environment-Based Configuration

```swift
struct AppConfiguration {
    static func configureLicenseSeat() {
        let apiKey = ProcessInfo.processInfo.environment["LICENSESEAT_API_KEY"] ?? ""

        #if DEBUG
        LicenseSeat.configure(apiKey: apiKey) { config in
            config.debug = true
            config.autoValidateInterval = 60 // Frequent validation in debug
        }
        #else
        LicenseSeat.configure(apiKey: apiKey) { config in
            config.autoValidateInterval = 3600
            config.strictOfflineFallback = true
            config.maxOfflineDays = 14
        }
        #endif
    }
}
```

---

## Entitlements

Check feature access based on license entitlements:

```swift
let status = LicenseSeat.shared.checkEntitlement("premium-features")

switch status.reason {
case nil where status.active:
    enablePremiumFeatures()
case .expired:
    showRenewalPrompt(expiresAt: status.expiresAt)
case .notFound:
    showUpgradePrompt()
case .noLicense:
    showActivationPrompt()
default:
    disablePremiumFeatures()
}
```

### Reactive Entitlement Monitoring

```swift
LicenseSeat.shared.entitlementPublisher(for: "api-access")
    .receive(on: DispatchQueue.main)
    .sink { status in
        apiAccessEnabled = status.active
        if let expiresAt = status.expiresAt {
            scheduleExpirationWarning(at: expiresAt)
        }
    }
    .store(in: &cancellables)
```

---

## Offline Validation

The SDK provides seamless offline support with Ed25519 cryptographic verification:

```swift
LicenseSeat.configure(apiKey: "YOUR_API_KEY") { config in
    config.strictOfflineFallback = true       // Network-only fallback mode
    config.maxOfflineDays = 7                 // 7-day grace period
    config.offlineLicenseRefreshInterval = 259200 // Refresh every 72 hours
}
```

### Offline Fallback Modes

- **`networkOnly`** (default): Falls back to offline validation only for network errors (timeouts, connectivity issues, 5xx responses). Business logic errors (4xx) immediately invalidate the license.
- **`always`**: Always attempts offline validation on any failure (legacy behavior).

---

## Event System

Subscribe to SDK events for analytics, UI updates, or custom logic:

```swift
// Subscribe with closure (returns AnyCancellable)
let cancellable = LicenseSeat.shared.on("activation:success") { data in
    print("License activated!")
    Analytics.track("license_activated")
}

// Unsubscribe by cancelling
cancellable.cancel()

// Or use Combine publishers
LicenseSeat.shared.eventPublisher
    .filter { $0.name.hasPrefix("validation:") }
    .sink { event in
        switch event.name {
        case "validation:success":
            updateUI()
        case "validation:offline-success":
            showOfflineBanner()
        case "license:revoked":
            lockFeatures()
        default:
            break
        }
    }
    .store(in: &cancellables)
```

### Available Events

| Event                                       | Description                      |
| ------------------------------------------- | -------------------------------- |
| `activation:start/success/error`            | License activation lifecycle     |
| `validation:start/success/failed/error`     | Online validation                |
| `validation:offline-success/offline-failed` | Offline validation               |
| `deactivation:start/success/error`          | License deactivation             |
| `license:loaded`                            | Cached license loaded at startup |
| `license:revoked`                           | License revoked by server        |
| `network:online/offline`                    | Connectivity changes             |
| `sdk:reset`                                 | SDK state cleared                |

---

## Platform Support

| Platform | Minimum Version | Notes                                |
| -------- | --------------- | ------------------------------------ |
| macOS    | 12.0+           | Full support including hardware UUID |
| iOS      | 13.0+           | Full support                         |
| tvOS     | 13.0+           | Full support                         |
| watchOS  | 8.0+            | Core features (no Network.framework) |

---

## Example App

An interactive CLI example is included for testing the SDK:

```bash
# From the repository root
swift run --package-path Examples/LicenseSeatExample

# Or with custom environment
export LICENSESEAT_API_URL=http://localhost:3000
export LICENSESEAT_API_KEY=sk_test_123
swift run --package-path Examples/LicenseSeatExample
```

The CLI lets you test activation, validation, entitlements, and deactivation interactively.

---

## Publishing & Distribution

### For SDK Users

To use LicenseSeat in your project, simply add the Swift Package Manager dependency as shown in [Installation](#installation). No additional setup is required—SPM handles fetching and building automatically.

### For SDK Maintainers: Publishing a New Version

1. **Ensure all tests pass:**
   ```bash
   swift test
   ```

2. **Update version references** (if any hardcoded versions exist in documentation)

3. **Create and push a git tag:**
   ```bash
   # Semantic versioning: MAJOR.MINOR.PATCH
   git tag v0.2.0
   git push origin v0.2.0
   ```

4. **Create a GitHub Release** (optional but recommended):
   - Go to **Releases** in the GitHub repository
   - Click **Draft a new release**
   - Select your tag, add release notes
   - Publish

That's it! Swift Package Manager uses git tags for versioning. Once a tag is pushed, users can immediately use the new version:

```swift
// Users can now specify the new version
.package(url: "https://github.com/licenseseat/licenseseat-swift.git", from: "0.2.0")
```

### Version Requirements for Users

| Requirement      | Example                         | Description                          |
| ---------------- | ------------------------------- | ------------------------------------ |
| `from:`          | `from: "0.2.0"`                 | Any version ≥ 0.2.0 (recommended)    |
| `exact:`         | `exact: "0.1.1"`                | Exactly version 0.1.1                |
| `upToNextMajor:` | `.upToNextMajor(from: "0.2.0")` | 0.x.x versions only                  |
| `upToNextMinor:` | `.upToNextMinor(from: "0.2.0")` | 0.1.x versions only                  |
| `branch:`        | `branch: "main"`                | Latest from branch (for development) |

### CI/CD

The repository includes GitHub Actions CI that runs on every push and PR:
- Tests on macOS (Xcode 15.4, 16.2)
- SwiftLint for code style
- DocC documentation generation

---

## API Documentation

Full API documentation is available at:
**[https://licenseseat.github.io/licenseseat-swift](https://licenseseat.github.io/licenseseat-swift/documentation/licenseseat/)**

### Generate Documentation Locally

```bash
# Generate and preview
swift package --allow-writing-to-directory ./docs \
    generate-documentation --target LicenseSeat \
    --output-path ./docs

# Open in browser
open ./docs/documentation/licenseseat/index.html
```

---

## Testing

```bash
# Run all tests
swift test

# Run with verbose output
swift test -v

# Run specific test
swift test --filter EntitlementTests

# Generate code coverage
swift test --enable-code-coverage
```

The SDK includes 77+ tests covering:
- License activation, validation, and deactivation
- Entitlement checking and parsing
- Offline cryptographic validation
- Event bus subscriptions
- Device identifier generation
- API client retry logic
- API response format compliance
- Error handling with reason codes

---

## Migration from JavaScript SDK

This Swift SDK provides feature parity with the official JavaScript SDK:

| JavaScript                   | Swift                                  |
| ---------------------------- | -------------------------------------- |
| `new LicenseSeat(config)`    | `LicenseSeat(config:)`                 |
| `sdk.activate(key, options)` | `sdk.activate(licenseKey:options:)`    |
| `sdk.validate(key, options)` | `sdk.validate(licenseKey:options:)`    |
| `sdk.deactivate()`           | `sdk.deactivate()`                     |
| `sdk.checkEntitlement(key)`  | `sdk.checkEntitlement(_:)`             |
| `sdk.getStatus()`            | `sdk.getStatus()` → enum               |
| `sdk.on('event', cb)`        | `sdk.on("event") { }` → AnyCancellable |

---

## License

MIT License. See [LICENSE.txt](LICENSE.txt) for details.

---

## Support

- **Documentation:** [https://docs.licenseseat.com](https://docs.licenseseat.com)
- **Issues:** [GitHub Issues](https://github.com/licenseseat/licenseseat-swift/issues)