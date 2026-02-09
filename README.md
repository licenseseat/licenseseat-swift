# LicenseSeat Swift SDK

[![Swift 5.9+](https://img.shields.io/badge/Swift-5.9+-F05138.svg?style=flat)](https://swift.org)
[![Platforms](https://img.shields.io/badge/Platforms-macOS%2012+%20|%20iOS%2013+%20|%20tvOS%2013+%20|%20watchOS%208+-blue.svg)](https://swift.org)
[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE.txt)
[![CI](https://github.com/licenseseat/licenseseat-swift/actions/workflows/ci.yml/badge.svg)](https://github.com/licenseseat/licenseseat-swift/actions/workflows/ci.yml)
[![Documentation](https://img.shields.io/badge/Docs-DocC-blue.svg)](https://licenseseat.github.io/licenseseat-swift/documentation/licenseseat/)

The official Swift SDK for [LicenseSeat](https://licenseseat.com) — the simple, secure licensing platform for apps, games, and plugins.

## Features

- **License Lifecycle** — Activate, validate, and deactivate licenses with async/await APIs
- **Product-Scoped Operations** — All operations are scoped to your product via `productSlug`
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
    - [Offline Token Structure](#offline-token-structure)
  - [Event System](#event-system)
    - [Available Events](#available-events)
  - [API Response Format](#api-response-format)
    - [Success Responses](#success-responses)
    - [Error Responses](#error-responses)
  - [Telemetry \& Privacy](#telemetry--privacy)
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
  - [Integration Tests (StressTest)](#integration-tests-stresstest)
  - [Migration from v1 SDK](#migration-from-v1-sdk)
  - [License](#license)
  - [Support](#support)

---

## Installation

### Swift Package Manager

Add LicenseSeat to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/licenseseat/licenseseat-swift.git", from: "0.3.1")
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

Configure LicenseSeat once at app launch. The `productSlug` is required for all license operations:

```swift
import LicenseSeat

// In your app's initialization (e.g., @main App.init or AppDelegate)
LicenseSeatStore.shared.configure(
    apiKey: "YOUR_API_KEY",
    productSlug: "your-product-slug"
)
```

### 2. Activate a License

When a user enters their license key:

```swift
do {
    let license = try await LicenseSeatStore.shared.activate("USER-LICENSE-KEY")
    print("Activated: \(license.licenseKey)")
    print("Device ID: \(license.deviceId)")
    print("Activation ID: \(license.activationId)")
} catch let error as APIError {
    print("Activation failed: \(error.code ?? "unknown") - \(error.message)")
} catch {
    print("Activation failed: \(error.localizedDescription)")
}
```

### 3. Check License Status

```swift
switch LicenseSeatStore.shared.status {
case .active(let details):
    print("Licensed! Device: \(details.device)")
case .offlineValid(let details):
    print("Valid offline until next sync")
case .inactive(let message):
    print("No license activated: \(message)")
case .invalid(let message):
    print("Invalid: \(message)")
case .pending(let message):
    print("Validating: \(message)")
case .offlineInvalid(let message):
    print("Offline validation failed: \(message)")
}
```

### 4. Deactivate

```swift
try await LicenseSeatStore.shared.deactivate()
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
        LicenseSeatStore.shared.configure(
            apiKey: ProcessInfo.processInfo.environment["LICENSESEAT_API_KEY"] ?? "",
            productSlug: "my-app"
        )
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
                        try await LicenseSeatStore.shared.activate(licenseKey)
                    } catch let apiError as APIError {
                        self.error = apiError.message
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
        LicenseSeatStore.shared.configure(
            apiKey: "YOUR_API_KEY",
            productSlug: "your-product"
        )

        // React to license status changes
        LicenseSeatStore.shared.$status
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in
                switch status {
                case .active, .offlineValid:
                    self?.isLicensed = true
                default:
                    self?.isLicensed = false
                }
            }
            .store(in: &cancellables)

        // Monitor specific entitlements
        LicenseSeatStore.shared.entitlementPublisher(for: "pro-features")
            .map { $0.active }
            .receive(on: DispatchQueue.main)
            .assign(to: &$hasProFeatures)
    }

    func activate(_ key: String) async throws {
        try await LicenseSeatStore.shared.activate(key)
    }

    func deactivate() async throws {
        try await LicenseSeatStore.shared.deactivate()
    }
}
```

---

## Advanced Usage

### Custom Configuration

For full control, create an instance with custom configuration:

```swift
let config = LicenseSeatConfig(
    apiBaseUrl: "https://licenseseat.com/api/v1",  // v1 API endpoint
    apiKey: "YOUR_API_KEY",
    productSlug: "your-product",                   // Required for all operations
    storagePrefix: "myapp_",
    autoValidateInterval: 3600,                    // Re-validate every hour
    maxRetries: 3,
    retryDelay: 1,
    offlineFallbackMode: .networkOnly,             // Offline fallback strategy
    maxOfflineDays: 7,                             // 7-day grace period
    maxClockSkewMs: 300000,                        // 5-minute clock tolerance
    debug: true
)

let licenseSeat = LicenseSeat(config: config)

// Use instance methods
let license = try await licenseSeat.activate(
    licenseKey: "USER-KEY",
    options: ActivationOptions(
        deviceId: "custom-device-id",
        deviceName: "User's MacBook Pro",
        metadata: ["version": "2.0.0", "environment": "production"]
    )
)

// Access activation details
print("License Key: \(license.licenseKey)")
print("Device ID: \(license.deviceId)")
print("Activation ID: \(license.activationId)")
print("Activated At: \(license.activatedAt)")
```

### Manual Validation

```swift
let result = try await licenseSeat.validate(licenseKey: license.licenseKey)

if result.valid {
    print("License is valid")
    print("Plan: \(result.license.planKey)")
    print("Status: \(result.license.status)")

    // Check entitlements from validation
    for entitlement in result.license.activeEntitlements {
        print("Entitlement: \(entitlement.key)")
        if let expiresAt = entitlement.expiresAt {
            print("  Expires: \(expiresAt)")
        }
    }
} else {
    print("License invalid: \(result.code ?? "unknown")")
    print("Message: \(result.message ?? "")")
}
```

---

## Configuration Options

| Option                      | Type                  | Default                            | Description                              |
| --------------------------- | --------------------- | ---------------------------------- | ---------------------------------------- |
| `apiBaseUrl`                | `String`              | `https://licenseseat.com/api/v1`   | v1 API endpoint                          |
| `apiKey`                    | `String?`             | `nil`                              | Your API key                             |
| `productSlug`               | `String?`             | `nil`                              | Product identifier (required)            |
| `storagePrefix`             | `String`              | `licenseseat_`                     | Prefix for cache keys                    |
| `deviceIdentifier`          | `String?`             | Auto-generated                     | Custom device ID                         |
| `autoValidateInterval`      | `TimeInterval`        | `3600` (1 hour)                    | Background validation interval           |
| `networkRecheckInterval`    | `TimeInterval`        | `30`                               | Offline connectivity check interval      |
| `maxRetries`                | `Int`                 | `3`                                | API retry attempts                       |
| `retryDelay`                | `TimeInterval`        | `1`                                | Base retry delay (exponential backoff)   |
| `offlineFallbackMode`       | `OfflineFallbackMode` | `.networkOnly`                     | Offline fallback strategy                |
| `offlineTokenRefreshInterval` | `TimeInterval`      | `259200` (72 hours)                | Offline token refresh interval           |
| `maxOfflineDays`            | `Int`                 | `0`                                | Grace period for offline use             |
| `maxClockSkewMs`            | `TimeInterval`        | `300000` (5 min)                   | Clock tamper tolerance                   |
| `telemetryEnabled`          | `Bool`                | `true`                             | Send device telemetry with API requests  |
| `debug`                     | `Bool`                | `false`                            | Enable debug logging                     |

### Environment-Based Configuration

```swift
struct AppConfiguration {
    static func configureLicenseSeat() {
        let apiKey = ProcessInfo.processInfo.environment["LICENSESEAT_API_KEY"] ?? ""
        let productSlug = ProcessInfo.processInfo.environment["LICENSESEAT_PRODUCT_SLUG"] ?? "my-app"

        #if DEBUG
        LicenseSeatStore.shared.configure(
            apiKey: apiKey,
            productSlug: productSlug
        ) { config in
            config.debug = true
            config.autoValidateInterval = 60 // Frequent validation in debug
        }
        #else
        LicenseSeatStore.shared.configure(
            apiKey: apiKey,
            productSlug: productSlug
        ) { config in
            config.autoValidateInterval = 3600
            config.offlineFallbackMode = .networkOnly
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
let status = LicenseSeatStore.shared.entitlement("premium-features")

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

// Access entitlement details
if let entitlement = status.entitlement {
    print("Entitlement key: \(entitlement.key)")
    if let metadata = entitlement.metadata {
        print("Metadata: \(metadata)")
    }
}
```

### Reactive Entitlement Monitoring

```swift
LicenseSeatStore.shared.entitlementPublisher(for: "api-access")
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
LicenseSeatStore.shared.configure(
    apiKey: "YOUR_API_KEY",
    productSlug: "your-product"
) { config in
    config.offlineFallbackMode = .networkOnly     // Network-first fallback mode
    config.maxOfflineDays = 7                     // 7-day grace period
    config.offlineTokenRefreshInterval = 259200   // Refresh every 72 hours
}
```

### Offline Fallback Modes

| Mode          | Description                                                                                         |
| ------------- | --------------------------------------------------------------------------------------------------- |
| `networkOnly` | Falls back to offline validation only for network errors (timeouts, connectivity issues, 5xx responses). Business logic errors (4xx) immediately invalidate the license. |
| `always`      | Always attempts offline validation on any failure.                                                   |

### Offline Token Structure

The SDK fetches and caches offline tokens for cryptographic verification. The token structure includes:

```swift
// Offline token payload fields
struct TokenPayload {
    let schemaVersion: Int      // Token schema version
    let licenseKey: String      // Associated license key
    let productSlug: String     // Product identifier
    let planKey: String         // License plan
    let mode: String            // License mode (e.g., "hardware_locked")
    let seatLimit: Int?         // Maximum seats
    let deviceId: String        // Bound device ID
    let iat: Int                // Issued at (Unix timestamp)
    let exp: Int                // Expires at (Unix timestamp)
    let nbf: Int                // Not before (Unix timestamp)
    let licenseExpiresAt: Int?  // License expiration (if applicable)
    let kid: String             // Signing key ID
    let entitlements: [...]     // Active entitlements
    let metadata: [...]?        // Custom metadata
}

// Signature block for Ed25519 verification
struct Signature {
    let algorithm: String       // "Ed25519"
    let keyId: String           // Key ID for lookup
    let value: String           // Base64URL-encoded signature
}
```

The SDK verifies offline tokens by:
1. Fetching the public key from `/signing-keys/{keyId}`
2. Verifying the Ed25519 signature against the canonical JSON
3. Checking token expiration (`exp`), not-before (`nbf`), and license expiration
4. Validating the grace period based on last online validation
5. Detecting clock tampering with `maxClockSkewMs` tolerance

---

## Event System

Subscribe to SDK events for analytics, UI updates, or custom logic:

```swift
// Subscribe with closure (returns AnyCancellable)
let cancellable = licenseSeat.on("activation:success") { data in
    print("License activated!")
    Analytics.track("license_activated")
}

// Unsubscribe by cancelling
cancellable.cancel()

// Or use Combine publishers
licenseSeat.eventPublisher
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

| Event                                       | Description                        |
| ------------------------------------------- | ---------------------------------- |
| `activation:start/success/error`            | License activation lifecycle       |
| `validation:start/success/failed/error`     | Online validation                  |
| `validation:offline-success/offline-failed` | Offline validation                 |
| `deactivation:start/success/error`          | License deactivation               |
| `license:loaded`                            | Cached license loaded at startup   |
| `license:revoked`                           | License revoked by server          |
| `offlineToken:verified`                     | Offline token signature verified   |
| `offlineToken:verificationFailed`           | Offline token verification failed  |
| `autovalidation:cycle`                      | Auto-validation cycle triggered    |
| `network:online/offline`                    | Connectivity changes               |
| `sdk:reset`                                 | SDK state cleared                  |

---

## API Response Format

The v1 API uses Stripe-style conventions with `object` fields identifying response types.

### Success Responses

**Activation Response:**
```json
{
  "object": "activation",
  "id": 12345,
  "device_id": "mac_abc123",
  "device_name": "User's MacBook",
  "license_key": "LICENSE-KEY",
  "activated_at": "2025-01-15T10:30:00Z",
  "deactivated_at": null,
  "ip_address": "192.168.1.1",
  "metadata": null,
  "license": {
    "object": "license",
    "key": "LICENSE-KEY",
    "status": "active",
    "starts_at": null,
    "expires_at": null,
    "mode": "hardware_locked",
    "plan_key": "pro",
    "seat_limit": 5,
    "active_seats": 1,
    "active_entitlements": [
      {"key": "premium", "expires_at": null, "metadata": null}
    ],
    "metadata": null,
    "product": {"slug": "my-app", "name": "My App"}
  }
}
```

**Validation Response:**
```json
{
  "object": "validation_result",
  "valid": true,
  "code": null,
  "message": null,
  "warnings": null,
  "license": { ... },
  "activation": { ... }
}
```

**Deactivation Response:**
```json
{
  "object": "deactivation",
  "activation_id": 12345,
  "deactivated_at": "2025-01-15T12:00:00Z"
}
```

### Error Responses

All errors use a nested format:

```json
{
  "error": {
    "code": "license_not_found",
    "message": "The specified license key was not found",
    "details": {
      "license_key": "INVALID-KEY"
    }
  }
}
```

Common error codes:
- `license_not_found` — License key doesn't exist
- `license_expired` — License has expired
- `license_suspended` — License has been suspended
- `seat_limit_exceeded` — No available seats
- `device_mismatch` — Device ID doesn't match activation
- `product_mismatch` — License not valid for this product

---

## Telemetry & Privacy

The SDK automatically collects non-personally identifiable device telemetry and sends it with every API request. This powers per-product analytics in the LicenseSeat dashboard: DAU/MAU, version adoption, platform distribution, and more.

### What's Collected

| Field | Example | Purpose |
|-------|---------|---------|
| `sdk_version` | `0.4.0` | SDK adoption tracking |
| `os_name` | `macOS` | Platform distribution |
| `os_version` | `15.2.0` | OS breakdown |
| `platform` | `macOS` | Platform analytics |
| `device_model` | `MacBookPro18,1` | Device analytics |
| `app_version` | `2.1.0` | Version adoption charts |
| `app_build` | `42` | Build tracking |
| `locale` | `en_US` | Localization insights |
| `timezone` | `America/New_York` | Geographic context |

The `device_id` (hardware UUID on macOS, composite hash on iOS) is sent as a top-level parameter for seat management. IP addresses are resolved server-side for country/city-level geolocation — the SDK never reads or sends the device's IP address itself.

### What's NOT Collected

- No names, emails, or user accounts
- No IP addresses from the device
- No file paths, browsing history, or app usage patterns
- No advertising identifiers (IDFA/IDFV)
- No cross-app tracking

### Disabling Telemetry

If your app needs to comply with GDPR or similar privacy regulations, you can disable telemetry entirely:

```swift
LicenseSeatStore.shared.configure(
    apiKey: "YOUR_API_KEY",
    productSlug: "your-product"
) { config in
    config.telemetryEnabled = false
}
```

When disabled, API requests still work normally — the SDK simply omits the `telemetry` object from request bodies. License activation, validation, deactivation, and heartbeat all function the same way.

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
export LICENSESEAT_API_URL=https://licenseseat.com/api/v1
export LICENSESEAT_API_KEY=sk_test_123
export LICENSESEAT_PRODUCT_SLUG=my-app
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
   git tag v0.3.1
   git push origin v0.3.1
   ```

4. **Create a GitHub Release** (optional but recommended):
   - Go to **Releases** in the GitHub repository
   - Click **Draft a new release**
   - Select your tag, add release notes
   - Publish

That's it! Swift Package Manager uses git tags for versioning. Once a tag is pushed, users can immediately use the new version:

```swift
// Users can now specify the new version
.package(url: "https://github.com/licenseseat/licenseseat-swift.git", from: "0.3.1")
```

### Version Requirements for Users

| Requirement      | Example                         | Description                          |
| ---------------- | ------------------------------- | ------------------------------------ |
| `from:`          | `from: "0.3.1"`                 | Any version >= 0.3.1 (recommended)   |
| `exact:`         | `exact: "0.3.1"`                | Exactly version 0.3.1                |
| `upToNextMajor:` | `.upToNextMajor(from: "0.3.1")` | 0.x.x versions only                  |
| `upToNextMinor:` | `.upToNextMinor(from: "0.3.1")` | 0.3.x versions only                  |
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

The SDK includes 70+ tests covering:
- License activation, validation, and deactivation
- Product-scoped API endpoints
- Entitlement checking and parsing
- Offline cryptographic token validation
- Event bus subscriptions
- Device identifier generation
- API client retry logic
- v1 API response format compliance
- Nested error handling with error codes

---

## Integration Tests (StressTest)

The `StressTest` directory contains a comprehensive end-to-end integration test that simulates real-world customer usage against the live LicenseSeat API. This test exercises the complete license lifecycle.

### What It Tests

The integration test simulates a real macOS app customer journey:

1. **First Launch & Activation** — Fresh install, license key entry, activation
2. **Auto-Validation Cycles** — Background validation with configurable intervals
3. **Offline Token Caching** — Ed25519 signed tokens for offline resilience
4. **Security & Tampering Detection** — Forged keys, wrong products, missing credentials
5. **License Persistence** — Data survives app restarts
6. **SwiftUI Integration** — LicenseSeatStore singleton reactive updates
7. **Deactivation & Re-activation** — Seat management for device transfers

### Running Integration Tests

```bash
# Navigate to the StressTest directory
cd StressTest

# Set required environment variables
export LICENSESEAT_API_KEY="your-api-key"
export LICENSESEAT_LICENSE_KEY="your-test-license-key"
export LICENSESEAT_PRODUCT_SLUG="your-product-slug"

# For local SDK development, modify Package.swift to use local path:
# .package(path: "..")

# Build and run
swift run
```

### Environment Variables

| Variable | Description |
|----------|-------------|
| `LICENSESEAT_API_KEY` | Your LicenseSeat API key |
| `LICENSESEAT_LICENSE_KEY` | A valid license key for testing |
| `LICENSESEAT_PRODUCT_SLUG` | The product slug matching your license |

### Sample Output

```
======================================================================
  SCENARIO 1: First App Launch (Fresh Install)
======================================================================

-> Testing: Initial state check (no license)
   ✅ PASS: App shows activation screen (no license)

-> Testing: User enters license key and clicks 'Activate'
   ✅ PASS: Activation successful!
   📝 Device ID: mac_abc123
   📝 Activation ID: act-12345-uuid

...

======================================================================
  RESULTS
======================================================================
  Passed: 23
  Failed: 0
  Total:  23
======================================================================

🎉 ALL SCENARIOS PASSED!
```

---

## Migration from v1 SDK

If you're upgrading from an earlier version of the SDK, here are the key changes:

### Configuration Changes

```swift
// Before (v0.x)
LicenseSeat.configure(apiKey: "YOUR_API_KEY")

// After (v2.0)
LicenseSeatStore.shared.configure(
    apiKey: "YOUR_API_KEY",
    productSlug: "your-product"  // Now required
)
```

### API URL Change

The base URL has changed from `/api` to `/api/v1`:
- Old: `https://licenseseat.com/api`
- New: `https://licenseseat.com/api/v1`

### Field Name Changes

| Old Field           | New Field    |
| ------------------- | ------------ |
| `device_identifier` | `device_id`  |
| `license_key`       | `key`        |
| `reason_code`       | `error.code` |

### Offline Configuration

```swift
// Before (v0.x)
config.offlineFallbackEnabled = true
config.offlineLicenseRefreshInterval = 259200

// After (v2.0)
config.offlineFallbackMode = .networkOnly  // or .always
config.offlineTokenRefreshInterval = 259200
```

### Error Handling

```swift
// Before (v0.x)
catch let error as APIError {
    print(error.reasonCode)
}

// After (v2.0)
catch let error as APIError {
    print(error.code)     // Error code from error.code
    print(error.message)  // Error message from error.message
    print(error.details)  // Optional additional details
}
```

---

## License

MIT License. See [LICENSE.txt](LICENSE.txt) for details.

---

## Support

- **Documentation:** [https://docs.licenseseat.com](https://docs.licenseseat.com)
- **Issues:** [GitHub Issues](https://github.com/licenseseat/licenseseat-swift/issues)
