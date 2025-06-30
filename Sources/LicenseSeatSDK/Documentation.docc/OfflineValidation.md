# Offline Validation

Master offline license validation for air-gapped environments and network resilience.

## Overview

LicenseSeat provides cryptographically secure offline validation using Ed25519 signatures. This enables your application to validate licenses without network connectivity, perfect for air-gapped environments, temporary network outages, or performance-critical scenarios.

## How Offline Validation Works

1. **Initial Online Activation** - License must be activated online at least once
2. **Offline License Download** - SDK automatically fetches signed offline license data
3. **Public Key Caching** - Ed25519 public keys are cached for signature verification
4. **Local Verification** - Licenses are verified using cryptographic signatures
5. **Fallback Logic** - Automatic fallback when network is unavailable

## Configuration

```swift
let config = LicenseSeatConfig(
    // Enable strict offline fallback (network-only)
    strictOfflineFallback: true,
    
    // Refresh offline license every 72 hours
    offlineLicenseRefreshInterval: 259200,
    
    // Allow 7 days of offline usage
    maxOfflineDays: 7,
    
    // Clock tamper tolerance
    maxClockSkewMs: 300000 // 5 minutes
)
```

## Offline Validation Flow

### Automatic Fallback

When network validation fails, the SDK automatically attempts offline validation:

```swift
do {
    // This will use offline validation if network fails
    let result = try await licenseSeat.validate(licenseKey: "KEY")
    
    if result.offline {
        print("Validated offline")
    }
} catch {
    print("Both online and offline validation failed")
}
```

### Manual Offline Check

You can also explicitly check the offline status:

```swift
// Get current status (may be offline-validated)
let status = licenseSeat.getStatus()

switch status {
case .offlineValid(let details):
    print("Valid offline until next sync")
case .offlineInvalid(let message):
    print("Offline validation failed: \(message)")
default:
    break
}
```

## Security Features

### Ed25519 Signature Verification

All offline licenses are signed with Ed25519:

```swift
// Signature verification happens automatically
// Payload structure:
{
    "lic_k": "LICENSE-KEY",
    "exp_at": "2025-01-01T00:00:00Z",
    "kid": "key-id-123",
    "entitlements": [...]
}
```

### Clock Tamper Detection

The SDK detects system clock manipulation:

```swift
// If clock is set backwards beyond tolerance:
// result.reasonCode == "clock_tamper"
```

### Grace Period Enforcement

When no expiration is set, grace period applies:

```swift
// License valid for maxOfflineDays since last online validation
// After grace period: reasonCode == "grace_period_expired"
```

## Offline Scenarios

### Air-Gapped Installation

```swift
// 1. Activate on internet-connected machine
let license = try await licenseSeat.activate(licenseKey: "KEY")

// 2. Export offline license data
let offlineData = licenseSeat.exportOfflineLicense()

// 3. Import on air-gapped machine
licenseSeat.importOfflineLicense(offlineData)

// 4. Validate offline
let status = licenseSeat.getStatus() // Works without internet
```

### Network Interruption Handling

```swift
// Monitor network status
licenseSeat.on("network:offline") { _ in
    showOfflineIndicator()
}

licenseSeat.on("validation:offline-success") { _ in
    print("Continuing with offline validation")
}
```

### Periodic Sync

```swift
// Offline licenses refresh automatically
// Monitor refresh events:
licenseSeat.on("offlineLicense:ready") { data in
    if let expiry = data["exp_at"] as? String {
        print("Offline license valid until: \(expiry)")
    }
}
```

## Best Practices

### 1. Pre-fetch Offline Assets

Ensure offline licenses are ready before network loss:

```swift
// Force sync on app launch
Task {
    await licenseSeat.syncOfflineAssets()
}
```

### 2. Monitor Expiration

Track offline license expiration:

```swift
licenseSeat.eventPublisher(for: "offlineLicense:fetched")
    .sink { event in
        if let data = event.data as? [String: Any],
           let payload = data["payload"] as? [String: Any],
           let expAt = payload["exp_at"] as? String {
            scheduleExpirationWarning(expAt)
        }
    }
    .store(in: &cancellables)
```

### 3. Handle Validation Failures

```swift
licenseSeat.on("validation:offline-failed") { data in
    if let result = data as? LicenseValidationResult {
        switch result.reasonCode {
        case "expired":
            showRenewalPrompt()
        case "no_offline_license":
            requireOnlineConnection()
        case "clock_tamper":
            showSecurityWarning()
        default:
            showGenericError()
        }
    }
}
```

## Troubleshooting

### Common Issues

1. **"no_offline_license"** - SDK hasn't downloaded offline data yet
   - Solution: Ensure at least one successful online validation

2. **"no_public_key"** - Public key not cached
   - Solution: SDK will fetch automatically when online

3. **"signature_invalid"** - Cryptographic verification failed
   - Solution: Ensure license hasn't been tampered with

4. **"license_mismatch"** - Offline license doesn't match cached license
   - Solution: Re-activate the license

## Platform Notes

- **macOS/iOS**: Uses system CryptoKit for Ed25519
- **Linux**: Falls back to SwiftCrypto package
- **Keychain**: Public keys stored in UserDefaults (consider Keychain for enhanced security)

## Advanced Usage

### Custom Offline Storage

```swift
// Export for custom storage
let offlineData = licenseSeat.currentOfflineLicense()
// Store in your secure storage

// Later, restore:
licenseSeat.importOfflineLicense(offlineData)
```

### Offline-First Architecture

```swift
class OfflineFirstLicenseManager {
    private let sdk = LicenseSeat.shared
    
    func validateWithFallback() async -> Bool {
        // Try offline first for instant response
        if let cached = sdk.currentLicense(),
           let validation = cached.validation,
           validation.valid && validation.offline {
            return true
        }
        
        // Then try online
        do {
            let result = try await sdk.validate(licenseKey: cached?.licenseKey ?? "")
            return result.valid
        } catch {
            // Network failed, already tried offline
            return false
        }
    }
}
``` 