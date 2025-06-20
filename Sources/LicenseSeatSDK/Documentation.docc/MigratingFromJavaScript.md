# Migrating from JavaScript

Comprehensive guide for migrating from the JavaScript SDK to Swift.

## Overview

The Swift SDK maintains full feature parity with the JavaScript SDK while embracing Swift's type safety, async/await patterns, and platform-specific features. This guide maps JavaScript patterns to their Swift equivalents.

## API Mapping

### Initialization

**JavaScript:**
```javascript
const sdk = new LicenseSeatSDK({
    apiBaseUrl: "https://api.licenseseat.com",
    apiKey: "your-key",
    autoValidateInterval: 3600000,
    debug: true
});
```

**Swift:**
```swift
let config = LicenseSeatConfig(
    apiBaseUrl: "https://api.licenseseat.com",
    apiKey: "your-key",
    autoValidateInterval: 3600, // seconds, not milliseconds
    debug: true
)
let sdk = LicenseSeat(config: config)
```

### License Activation

**JavaScript:**
```javascript
try {
    const license = await sdk.activate("LICENSE-KEY", {
        deviceIdentifier: "custom-id",
        metadata: { version: "1.0" }
    });
} catch (error) {
    console.error(error);
}
```

**Swift:**
```swift
do {
    let license = try await sdk.activate(
        licenseKey: "LICENSE-KEY",
        options: ActivationOptions(
            deviceIdentifier: "custom-id",
            metadata: ["version": "1.0"]
        )
    )
} catch {
    print(error)
}
```

### Validation

**JavaScript:**
```javascript
const result = await sdk.validateLicense("KEY", {
    productSlug: "pro"
});
if (result.valid) {
    // License is valid
}
```

**Swift:**
```swift
let result = try await sdk.validate(
    licenseKey: "KEY",
    options: ValidationOptions(productSlug: "pro")
)
if result.valid {
    // License is valid
}
```

### Event Handling

**JavaScript:**
```javascript
const unsubscribe = sdk.on("validation:success", (data) => {
    console.log("Validated!", data);
});

// Later
unsubscribe();
```

**Swift:**
```swift
let cancellable = sdk.on("validation:success") { data in
    print("Validated!", data)
}

// Later
cancellable.cancel()
```

### Status Checking

**JavaScript:**
```javascript
const status = sdk.getStatus();
switch (status.status) {
    case "active":
        console.log("Active license:", status.license);
        break;
    case "invalid":
        console.log("Invalid:", status.message);
        break;
}
```

**Swift:**
```swift
let status = sdk.getStatus()
switch status {
case .active(let details):
    print("Active license:", details.license)
case .invalid(let message):
    print("Invalid:", message)
default:
    break
}
```

## Configuration Differences

### Time Units

| JavaScript | Swift | Notes |
|------------|-------|-------|
| `autoValidateInterval: 3600000` | `autoValidateInterval: 3600` | JS uses milliseconds, Swift uses seconds |
| `retryDelay: 1000` | `retryDelay: 1` | JS uses milliseconds, Swift uses seconds |
| `maxClockSkewMs: 300000` | `maxClockSkewMs: 300000` | Both use milliseconds for precision |

### Storage

**JavaScript:**
```javascript
// Uses localStorage with optional encryption
const cache = new LicenseCache("prefix_");
```

**Swift:**
```swift
// Uses UserDefaults + file storage
let cache = LicenseCache(prefix: "prefix_")
// Keychain integration available for sensitive data
```

## Platform-Specific Features

### Device Identification

**JavaScript:**
```javascript
// Canvas fingerprinting + browser data
generateDeviceId() {
    return `web-${hashCode}-${timestamp}`;
}
```

**Swift:**
```swift
// Hardware UUID on macOS, composite ID on iOS
DeviceIdentifier.generate()
// Returns: "mac-hardware-uuid" or "ios-composite-id"
```

### Network Monitoring

**JavaScript:**
```javascript
// Polling-based with fetch API
sdk.on("network:offline", () => {
    // Handle offline
});
```

**Swift:**
```swift
// Native Network.framework integration
sdk.networkStatusPublisher
    .sink { isOnline in
        // Real-time network status
    }
```

## Error Handling

### Error Types

**JavaScript:**
```javascript
try {
    await sdk.activate(key);
} catch (error) {
    if (error instanceof APIError) {
        console.log("Status:", error.status);
    }
}
```

**Swift:**
```swift
do {
    try await sdk.activate(licenseKey: key)
} catch let error as APIError {
    print("Status:", error.status)
} catch let error as LicenseSeatError {
    switch error {
    case .noActiveLicense:
        print("No active license")
    case .invalidOfflineLicense:
        print("Invalid offline license")
    default:
        break
    }
}
```

## Async Patterns

### Promises to Async/Await

**JavaScript:**
```javascript
sdk.activate(key)
    .then(license => {
        return sdk.validateLicense(license.license_key);
    })
    .then(result => {
        console.log("Valid:", result.valid);
    })
    .catch(error => {
        console.error(error);
    });
```

**Swift:**
```swift
Task {
    do {
        let license = try await sdk.activate(licenseKey: key)
        let result = try await sdk.validate(licenseKey: license.licenseKey)
        print("Valid:", result.valid)
    } catch {
        print(error)
    }
}
```

## Reactive Patterns

### JavaScript (Custom Events)
```javascript
class LicenseManager {
    constructor() {
        this.status = "inactive";
        sdk.on("validation:success", () => {
            this.status = "active";
            this.updateUI();
        });
    }
}
```

### Swift (Combine)
```swift
class LicenseManager: ObservableObject {
    @Published var status: LicenseStatus = .inactive(message: "")
    
    init() {
        sdk.statusPublisher
            .assign(to: &$status)
    }
}
```

## Feature Comparison

| Feature | JavaScript | Swift | Notes |
|---------|------------|-------|-------|
| Activation | ✅ | ✅ | Identical API |
| Validation | ✅ | ✅ | Identical API |
| Offline Validation | ✅ | ✅ | Ed25519 on both |
| Auto-Validation | ✅ | ✅ | Timer-based |
| Events | ✅ | ✅ | + Combine publishers |
| Retry Logic | ✅ | ✅ | Exponential backoff |
| Device ID | ✅ | ✅ | Platform-specific |
| Clock Tamper | ✅ | ✅ | Identical detection |
| Grace Period | ✅ | ✅ | Identical logic |
| Entitlements | ✅ | ✅ | Identical API |

## Migration Checklist

1. **Update Time Units**
   - Convert milliseconds to seconds for intervals
   - Keep milliseconds for `maxClockSkewMs`

2. **Replace Callbacks with Async/Await**
   - Use `try await` instead of `.then()`
   - Use `do-catch` instead of `.catch()`

3. **Update Event Handlers**
   - Replace `unsubscribe()` with `cancellable.cancel()`
   - Consider using Combine publishers

4. **Type Safety**
   - Replace string statuses with enums
   - Use proper option types instead of plain objects

5. **Platform Features**
   - Leverage SwiftUI/UIKit integration
   - Use native networking APIs
   - Consider Keychain for sensitive storage

## Common Pitfalls

### 1. Time Unit Confusion
```swift
// ❌ Wrong - using milliseconds
let config = LicenseSeatConfig(autoValidateInterval: 3600000)

// ✅ Correct - using seconds
let config = LicenseSeatConfig(autoValidateInterval: 3600)
```

### 2. Synchronous Expectations
```swift
// ❌ Wrong - expecting synchronous result
let status = sdk.validate(licenseKey: key) // Won't compile

// ✅ Correct - using async/await
let status = try await sdk.validate(licenseKey: key)
```

### 3. Event Handler Memory Leaks
```swift
// ❌ Wrong - strong reference cycle
sdk.on("event") { data in
    self.handleEvent(data) // Retains self
}

// ✅ Correct - weak reference
sdk.on("event") { [weak self] data in
    self?.handleEvent(data)
}
```

## Testing Differences

**JavaScript:**
```javascript
// Mock fetch API
global.fetch = jest.fn(() => 
    Promise.resolve({
        json: () => Promise.resolve({ valid: true })
    })
);
```

**Swift:**
```swift
// Mock URLProtocol
MockURLProtocol.requestHandler = { request in
    let response = HTTPURLResponse(/*...*/)
    let data = try JSONEncoder().encode(["valid": true])
    return (response, data)
}
```

## Next Steps

1. Review the <doc:GettingStarted> guide for Swift-specific setup
2. Explore <doc:ReactiveIntegration> for SwiftUI patterns
3. Check <doc:SecurityFeatures> for platform-specific security
4. See the example app for complete implementation patterns 