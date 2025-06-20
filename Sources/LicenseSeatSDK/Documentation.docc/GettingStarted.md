# Getting Started with LicenseSeatSDK

Learn how to integrate LicenseSeatSDK into your Swift application.

## Overview

This guide walks you through the initial setup and basic usage of LicenseSeatSDK. You'll learn how to configure the SDK, activate a license, and check entitlements.

## Installation

### Swift Package Manager

Add LicenseSeatSDK to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/licenseseat/licenseseat-swift.git", from: "1.0.0")
]
```

Or add it through Xcode:
1. File → Add Package Dependencies
2. Enter the repository URL
3. Select your target

## Basic Setup

### Step 1: Configure the SDK

```swift
import LicenseSeatSDK

// Create configuration
let config = LicenseSeatConfig(
    apiBaseUrl: "https://api.licenseseat.com",
    apiKey: "your-api-key",
    autoValidateInterval: 3600, // 1 hour
    offlineFallbackEnabled: true
)

// Initialize SDK
let licenseSeat = LicenseSeat(config: config)
```

### Step 2: Activate a License

```swift
do {
    let license = try await licenseSeat.activate(
        licenseKey: "USER-LICENSE-KEY",
        options: ActivationOptions(
            metadata: ["app_version": "1.0.0"]
        )
    )
    
    print("License activated: \(license.licenseKey)")
} catch {
    print("Activation failed: \(error)")
}
```

### Step 3: Check License Status

```swift
let status = licenseSeat.getStatus()

switch status {
case .active(let details):
    print("License is active: \(details.license)")
case .inactive(let message):
    print("No license: \(message)")
case .invalid(let message):
    print("Invalid license: \(message)")
case .pending(let message):
    print("Validation pending: \(message)")
case .offlineValid(let details):
    print("Valid (offline): \(details.license)")
case .offlineInvalid(let message):
    print("Invalid (offline): \(message)")
}
```

### Step 4: Check Entitlements

```swift
let premiumStatus = licenseSeat.checkEntitlement("premium-features")

if premiumStatus.active {
    // Enable premium features
    enablePremiumUI()
} else {
    switch premiumStatus.reason {
    case .expired:
        showExpiredMessage()
    case .notFound:
        showUpgradePrompt()
    case .noLicense:
        showActivationPrompt()
    default:
        break
    }
}
```

## Event Handling

### Using Callbacks

```swift
// Subscribe to events
let cancellable = licenseSeat.on("validation:success") { data in
    print("License validated successfully")
}

// Unsubscribe when done
licenseSeat.off("validation:success", handler: cancellable)
```

### Using Combine

```swift
import Combine

// Subscribe to status changes
licenseSeat.statusPublisher
    .sink { status in
        updateUI(for: status)
    }
    .store(in: &cancellables)

// Monitor network status
licenseSeat.networkStatusPublisher
    .sink { isOnline in
        print("Network status: \(isOnline ? "Online" : "Offline")")
    }
    .store(in: &cancellables)
```

## Best Practices

1. **Store API Key Securely** - Never hardcode your API key. Use environment variables or secure storage.

2. **Handle Offline Scenarios** - Always enable offline fallback for better user experience.

3. **Monitor Events** - Subscribe to SDK events to provide real-time feedback to users.

4. **Validate on Launch** - Check cached licenses on app startup for immediate access.

5. **Clean Up** - Call `reset()` when the user logs out or switches accounts.

## Next Steps

- Learn about <doc:OfflineValidation> for robust offline support
- Explore <doc:NetworkResilience> for handling connectivity issues
- See <doc:ReactiveIntegration> for SwiftUI integration patterns

## Complete Feature Set

### Configuration Options

```swift
let config = LicenseSeatConfig(
    apiBaseUrl: "https://api.licenseseat.com",     // API endpoint
    apiKey: "your-api-key",                        // Authentication
    storagePrefix: "myapp_",                       // Cache namespace
    deviceIdentifier: nil,                         // Custom device ID
    autoValidateInterval: 3600,                    // Validation frequency (seconds)
    networkRecheckInterval: 30,                    // Offline retry interval
    maxRetries: 3,                                 // API retry attempts
    retryDelay: 1,                                 // Base retry delay (seconds)
    debug: true,                                   // Enable logging
    offlineLicenseRefreshInterval: 259200,         // 72 hours
    offlineFallbackEnabled: true,                  // Enable offline mode
    maxOfflineDays: 7,                            // Grace period when offline
    maxClockSkewMs: 300000                        // 5 minutes clock tolerance
)
```

### License Validation

```swift
// Manual validation
do {
    let result = try await licenseSeat.validate(
        licenseKey: "USER-KEY",
        options: ValidationOptions(
            productSlug: "pro-edition"
        )
    )
    
    if result.valid {
        print("License is valid!")
    }
} catch {
    print("Validation error: \(error)")
}
```

### Deactivation

```swift
// Deactivate current license
do {
    try await licenseSeat.deactivate()
    print("License deactivated")
} catch {
    print("Deactivation failed: \(error)")
}
```

### Authentication Testing

```swift
// Verify API key is valid
do {
    let response = try await licenseSeat.testAuth()
    print("Auth test: \(response.success)")
} catch {
    print("Auth failed: \(error)")
}
```

### Advanced Activation

```swift
let options = ActivationOptions(
    deviceIdentifier: "custom-device-id",
    softwareReleaseDate: "2024-01-15T00:00:00Z",
    metadata: [
        "os_version": ProcessInfo.processInfo.operatingSystemVersionString,
        "app_version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
        "environment": "production"
    ]
)

let license = try await licenseSeat.activate(licenseKey: key, options: options)
```

### Event Types

Available events for monitoring:
- `license:loaded` - Cached license loaded on init
- `activation:start` / `activation:success` / `activation:error`
- `validation:start` / `validation:success` / `validation:failed` / `validation:error`
- `validation:offline-success` / `validation:offline-failed`
- `validation:auth-failed` / `validation:auto-failed`
- `deactivation:start` / `deactivation:success` / `deactivation:error`
- `autovalidation:cycle` / `autovalidation:stopped`
- `network:online` / `network:offline`
- `offlineLicense:fetching` / `offlineLicense:fetched` / `offlineLicense:fetchError`
- `offlineLicense:ready` / `offlineLicense:verified` / `offlineLicense:verificationFailed`
- `auth_test:start` / `auth_test:success` / `auth_test:error`
- `sdk:error` / `sdk:reset`

### SwiftUI Integration

```swift
@MainActor
class LicenseViewModel: ObservableObject {
    @Published var status: LicenseStatus = .inactive(message: "No license")
    private let sdk = LicenseSeat.shared
    private var cancellables = Set<AnyCancellable>()
    
    init() {
        sdk.statusPublisher
            .receive(on: DispatchQueue.main)
            .assign(to: &$status)
    }
}

struct ContentView: View {
    @StateObject private var license = LicenseViewModel()
    
    var body: some View {
        switch license.status {
        case .active:
            MainAppView()
        case .inactive, .invalid:
            LicenseActivationView()
        default:
            ProgressView("Validating license...")
        }
    }
}
``` 