# ``LicenseSeat``

A comprehensive Swift SDK for managing software licenses with the LicenseSeat licensing system.

## Overview

LicenseSeat provides a complete solution for integrating license management into your Swift applications. With a simple two-line integration and support for advanced features like offline validation, automatic re-validation, and entitlement management, it offers everything you need for robust license control.

### Quick Integration

```swift
// 1️⃣ Configure once at app launch
LicenseSeat.configure(apiKey: "YOUR_API_KEY")

// 2️⃣ Activate when user enters their license
try await LicenseSeat.activate("USER-LICENSE-KEY")

// ✅ That's it! The SDK handles everything else
```

### Key Features

- **Simple Static API** - Clean, modern Swift interface following SDK best practices
- **License Lifecycle** - Activation, validation, and deactivation with async/await
- **Offline Validation** - Ed25519 cryptographic verification for resilient offline use
- **Auto Re-validation** - Background validation keeps licenses current automatically
- **Entitlements** - Control feature access with fine-grained entitlement checks
- **Network Resilience** - Automatic retry, exponential backoff, and offline fallback
- **Reactive UI** - SwiftUI property wrappers and Combine publishers
- **Security** - Clock tamper detection, secure caching, and device fingerprinting
- **Multi-Platform** - Full support for macOS, iOS, tvOS, watchOS, and Linux

## Topics

### Getting Started

- <doc:GettingStarted>
- ``LicenseSeat``
- ``LicenseSeatConfig``

### Core APIs

- ``License``
- ``LicenseStatus``
- ``ActivationOptions``
- ``ValidationOptions``

### Entitlements

- ``Entitlement``
- ``EntitlementStatus``
- ``EntitlementInactiveReason``

### SwiftUI Integration

- <doc:ReactiveIntegration>
- ``LicenseState``
- ``EntitlementState``
- <doc:LicenseSeatStore>

### Advanced Features

- <doc:OfflineValidation>
- <doc:NetworkResilience>
- <doc:SecurityFeatures>

### Reference

- ``LicenseValidationResult``
- ``LicenseStatusDetails``
- ``ActivationResult``
- ``LicenseSeatError``
- ``APIError``

### Platform Guides

- <doc:SwiftUIIntegration>
- <doc:AppKitIntegration>
- <doc:LinuxSupport>

### Migration

- <doc:MigratingFromJavaScript> 