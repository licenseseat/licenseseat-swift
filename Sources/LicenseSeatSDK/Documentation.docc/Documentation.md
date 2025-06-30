# ``LicenseSeat``

A comprehensive Swift SDK for managing software licenses with the LicenseSeat licensing system.

## Overview

LicenseSeat provides a complete solution for integrating license management into your macOS and iOS applications. With support for online validation, offline verification, automatic re-validation, and entitlement checking, it offers everything you need for robust license management.

### Key Features

- **License Activation & Deactivation** - Simple async/await APIs for license lifecycle management
- **Online & Offline Validation** - Cryptographically secure offline license verification using Ed25519
- **Automatic Re-validation** - Configurable background validation to ensure licenses stay current
- **Entitlement Management** - Fine-grained feature access control with expiration support
- **Network Resilience** - Automatic retry with exponential backoff and offline fallback
- **Event-Driven Architecture** - Combine publishers and traditional callbacks for reactive UIs
- **Device Fingerprinting** - Platform-specific device identification with hardware UUID support
- **Security Features** - Clock tamper detection, grace periods, and secure caching

## Topics

### Essentials

- ``LicenseSeat``
- ``LicenseSeatConfig``
- <doc:GettingStarted>

### License Management

- ``License``
- ``ActivationResult``
- ``LicenseValidationResult``
- ``LicenseStatus``
- ``LicenseStatusDetails``
- ``ActivationOptions``
- ``ValidationOptions``

### Entitlements

- ``Entitlement``
- ``EntitlementStatus``
- ``EntitlementInactiveReason``

### Advanced Features

- <doc:OfflineValidation>
- <doc:NetworkResilience>
- <doc:ReactiveIntegration>
- <doc:SecurityFeatures>
- <doc:EventSystem>

### Storage & Caching

- <doc:CacheManagement>
- <doc:CustomStorage>

### Networking

- <doc:APIConfiguration>
- <doc:RetryLogic>

### Error Handling

- ``LicenseSeatError``
- ``APIError``

### Platform Integration

- <doc:SwiftUIIntegration>
- <doc:AppKitIntegration>
- <doc:LinuxSupport>

### Migration

- <doc:MigratingFromJavaScript> 