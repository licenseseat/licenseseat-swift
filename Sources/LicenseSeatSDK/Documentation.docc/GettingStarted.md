# Getting Started with LicenseSeat

Learn how to integrate LicenseSeat into your Swift application.

## Overview

LicenseSeat provides two integration approaches:

1. **Quick Integration** - Use the static methods on `LicenseSeat` for the simplest setup
2. **Advanced Control** - Create custom instances for complete control

This guide covers both approaches, starting with the recommended quick integration.

## Installation

Add LicenseSeat to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/licenseseat/licenseseat-swift.git", from: "1.0.0")
]
```

Or add it through Xcode:
1. File → Add Package Dependencies
2. Enter: `https://github.com/licenseseat/licenseseat-swift.git`
3. Select your target

## Quick Start (Recommended)

### Step 1: Configure at App Launch

```swift
import LicenseSeat

// In your app delegate or @main struct
LicenseSeat.configure(apiKey: "YOUR_API_KEY")
```

### Step 2: Activate a License

```swift
do {
    let license = try await LicenseSeat.activate("USER-LICENSE-KEY")
    print("Activated for device: \(license.deviceIdentifier)")
} catch {
    print("Activation failed: \(error)")
}
```

### Step 3: Check Status Anywhere

```swift
// Get current status
switch LicenseSeat.shared.getStatus() {
case .active(let details):
    print("Licensed to: \(details.license)")
    enableFullFeatures()
    
case .inactive:
    showActivationPrompt()
    
case .invalid(let message):
    showError(message)
    
case .pending:
    showLoadingIndicator()
    
case .offlineValid:
    enableFullFeatures()
    showOfflineBanner()
    
case .offlineInvalid:
    showExpiredLicenseError()
}

// Check specific entitlements
if LicenseSeat.shared.checkEntitlement("premium-features").active {
    enablePremiumFeatures()
}
```

### Step 4: React to Changes

```swift
import Combine

// Subscribe to status changes
LicenseSeat.statusPublisher
    .sink { status in
        updateUIForLicenseStatus(status)
    }
    .store(in: &cancellables)

// Monitor specific entitlements
LicenseSeat.shared.entitlementPublisher(for: "api-access")
    .map { $0.active }
    .removeDuplicates()
    .sink { hasAPIAccess in
        apiClient.isEnabled = hasAPIAccess
    }
    .store(in: &cancellables)
```

## SwiftUI Integration

### Using Property Wrappers

```swift
import SwiftUI
import LicenseSeat

struct ContentView: View {
    @LicenseState private var licenseStatus
    @EntitlementState("pro-features") private var hasProFeatures
    
    var body: some View {
        Group {
            switch licenseStatus {
            case .active, .offlineValid:
                MainAppView()
                    .environment(\.proFeaturesEnabled, hasProFeatures)
                
            case .inactive:
                LicenseActivationView()
                
            case .invalid(let message):
                ErrorView(message: message)
                
            case .pending:
                ProgressView("Validating license...")
                
            case .offlineInvalid:
                ExpiredLicenseView()
            }
        }
    }
}
```

### Manual Binding

```swift
@MainActor
class LicenseViewModel: ObservableObject {
    @Published var isLicensed = false
    @Published var canExportPDF = false
    
    private var cancellables = Set<AnyCancellable>()
    
    init() {
        // Monitor license status
        LicenseSeat.statusPublisher
            .map { $0.isValid }
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .assign(to: &$isLicensed)
        
        // Monitor specific entitlement
        LicenseSeat.shared.entitlementPublisher(for: "pdf-export")
            .map { $0.active }
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .assign(to: &$canExportPDF)
    }
    
    func activate(_ key: String) async throws {
        try await LicenseSeat.activate(key)
    }
}
```

## Advanced Usage

### Custom Configuration

```swift
// Configure with custom settings
LicenseSeat.configure(
    apiKey: "YOUR_API_KEY",
    apiBaseURL: URL(string: "https://api.licenseseat.com")!
) { config in
    config.autoValidateInterval = 3600          // Validate every hour
    config.offlineFallbackEnabled = true        // Enable offline mode
    config.maxOfflineDays = 7                   // 7-day grace period
    config.debug = true                         // Enable debug logging
}
```

### Multiple Instances

For complex scenarios requiring multiple configurations:

```swift
// Production instance
let production = LicenseSeat(
    config: LicenseSeatConfig(
        apiKey: "prod_key",
        apiBaseUrl: "https://api.licenseseat.com"
    )
)

// Staging instance for testing
let staging = LicenseSeat(
    config: LicenseSeatConfig(
        apiKey: "staging_key",
        apiBaseUrl: "https://staging.licenseseat.com",
        debug: true
    )
)

// Use instances directly
let license = try await production.activate(licenseKey: "KEY")
```

### Event Monitoring

```swift
// Subscribe to SDK events
LicenseSeat.shared.on("activation:success") { license in
    Analytics.track("License Activated", properties: [
        "device": license.deviceIdentifier
    ])
}

LicenseSeat.shared.on("validation:offline-success") { _ in
    showOfflineModeBanner()
}

// Available events:
// - activation:start/success/error
// - validation:start/success/failed/error
// - validation:offline-success/offline-failed
// - deactivation:start/success/error
// - network:online/offline
// - license:loaded
```

## Best Practices

### 1. Secure API Key Storage

```swift
// Use environment variables
let apiKey = ProcessInfo.processInfo.environment["LICENSESEAT_API_KEY"] ?? ""

// Or use a configuration file excluded from version control
if let path = Bundle.main.path(forResource: "Config", ofType: "plist"),
   let config = NSDictionary(contentsOfFile: path),
   let apiKey = config["LicenseSeatAPIKey"] as? String {
    LicenseSeat.configure(apiKey: apiKey)
}
```

### 2. Handle All States

```swift
func updateUI(for status: LicenseStatus) {
    switch status {
    case .active:
        // Full access
        enableAllFeatures()
        
    case .offlineValid:
        // Full access with offline indicator
        enableAllFeatures()
        showOfflineIndicator()
        
    case .pending:
        // Show loading state
        showLoadingView()
        
    case .inactive:
        // Prompt for activation
        showActivationView()
        
    case .invalid, .offlineInvalid:
        // Show appropriate error
        showLicenseErrorView()
    }
}
```

### 3. Graceful Offline Handling

```swift
LicenseSeat.configure(apiKey: apiKey) { config in
    config.offlineFallbackEnabled = true
    config.maxOfflineDays = 14  // Two weeks grace period
}

// Monitor network status
LicenseSeat.shared.networkStatusPublisher
    .sink { isOnline in
        if !isOnline {
            showOfflineNotification()
        }
    }
    .store(in: &cancellables)
```

### 4. Clean Up on Logout

```swift
func logout() async {
    do {
        try await LicenseSeat.deactivate()
    } catch {
        // Log error but continue with logout
        print("Deactivation error: \(error)")
    }
    
    // Clear all SDK data
    LicenseSeat.shared.reset()
    
    // Navigate to login
    showLoginScreen()
}
```

## Troubleshooting

### Debug Logging

Enable debug mode to see detailed logs:

```swift
LicenseSeat.configure(apiKey: apiKey) { config in
    config.debug = true
}
```

### Common Issues

1. **"No API key configured"** - Ensure you call `LicenseSeat.configure()` before any other SDK methods

2. **Offline validation failing** - Check that `offlineFallbackEnabled` is true and public keys are synced

3. **Device limit reached** - The user needs to deactivate on another device or upgrade their license

## Next Steps

- Learn about <doc:OfflineValidation> for robust offline support
- Explore <doc:NetworkResilience> for handling connectivity issues
- See <doc:ReactiveIntegration> for advanced SwiftUI patterns
- Review <doc:SecurityFeatures> for security best practices

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