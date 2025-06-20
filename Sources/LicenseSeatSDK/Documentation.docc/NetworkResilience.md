# Network Resilience

Build robust applications that handle network failures gracefully.

## Overview

LicenseSeatSDK is designed to work reliably in challenging network conditions. With automatic retry logic, exponential backoff, offline fallback, and intelligent connection monitoring, your application remains functional even when connectivity is intermittent or unavailable.

## Retry Logic

### Automatic Retries

The SDK automatically retries failed requests with exponential backoff:

```swift
let config = LicenseSeatConfig(
    maxRetries: 3,        // Number of retry attempts
    retryDelay: 1.0       // Base delay in seconds
)

// Retry delays: 1s, 2s, 4s (exponential backoff)
```

### Retry Conditions

The SDK retries on:
- Network timeouts (URLError)
- Server errors (502, 503, 504)
- Rate limiting (429)
- Connection failures

The SDK does NOT retry on:
- Client errors (4xx)
- Server errors (500, 501)
- Authentication failures

## Connection Monitoring

### Network Status Events

```swift
// Monitor connectivity changes
licenseSeat.on("network:online") { _ in
    updateUIForOnline()
}

licenseSeat.on("network:offline") { _ in
    updateUIForOffline()
}

// Using Combine
licenseSeat.networkStatusPublisher
    .sink { isOnline in
        connectionIndicator.isHidden = isOnline
    }
    .store(in: &cancellables)
```

### Platform-Specific Monitoring

- **macOS/iOS**: Uses `NWPathMonitor` for instant detection
- **Linux**: Falls back to periodic heartbeat checks

## Handling Network Failures

### Graceful Degradation

```swift
do {
    let result = try await licenseSeat.validate(licenseKey: "KEY")
    // Online validation succeeded
} catch let error as APIError where error.status == 0 {
    // Network failure - SDK will attempt offline validation
    print("Network unavailable, using cached license")
} catch {
    // Other errors
    handleError(error)
}
```

### Offline Queue Pattern

```swift
class ResilientLicenseManager {
    private var pendingValidations: [String] = []
    private let sdk = LicenseSeat.shared
    
    func validateWhenPossible(licenseKey: String) {
        sdk.on("network:online") { [weak self] _ in
            self?.processPendingValidations()
        }
        
        if sdk.isOnline {
            Task { try? await sdk.validate(licenseKey: licenseKey) }
        } else {
            pendingValidations.append(licenseKey)
        }
    }
    
    private func processPendingValidations() {
        let pending = pendingValidations
        pendingValidations.removeAll()
        
        for key in pending {
            Task { try? await sdk.validate(licenseKey: key) }
        }
    }
}
```

## Configuration Options

### Network Timeouts

```swift
// The SDK uses these timeouts internally:
// - Request timeout: 30 seconds
// - Resource timeout: 60 seconds

// For offline retry when disconnected:
let config = LicenseSeatConfig(
    networkRecheckInterval: 30  // Check every 30 seconds
)
```

### Custom Retry Strategy

```swift
// Implement custom retry logic
class CustomRetryHandler {
    private let sdk = LicenseSeat.shared
    private var retryCount = 0
    
    func validateWithCustomRetry(licenseKey: String) async throws -> LicenseValidationResult {
        while retryCount < 5 {
            do {
                let result = try await sdk.validate(licenseKey: licenseKey)
                retryCount = 0
                return result
            } catch {
                retryCount += 1
                let delay = Double(retryCount) * 2.0
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                
                if retryCount >= 5 {
                    throw error
                }
            }
        }
        throw LicenseSeatError.networkError
    }
}
```

## Best Practices

### 1. Always Enable Offline Fallback

```swift
let config = LicenseSeatConfig(
    offlineFallbackEnabled: true  // Default, but be explicit
)
```

### 2. Handle Transient Failures

```swift
licenseSeat.on("validation:auto-failed") { data in
    // Don't immediately show error - might be transient
    // The SDK will retry automatically
}
```

### 3. Provide Network Feedback

```swift
class NetworkStatusView: UIView {
    override init(frame: CGRect) {
        super.init(frame: frame)
        
        LicenseSeat.shared.networkStatusPublisher
            .removeDuplicates()
            .sink { [weak self] isOnline in
                self?.updateAppearance(online: isOnline)
            }
            .store(in: &cancellables)
    }
    
    private func updateAppearance(online: Bool) {
        backgroundColor = online ? .systemGreen : .systemOrange
        label.text = online ? "Online" : "Offline Mode"
    }
}
```

### 4. Batch Operations

```swift
// Batch multiple operations to reduce network overhead
extension LicenseSeat {
    func validateMultiple(keys: [String]) async -> [String: LicenseValidationResult] {
        await withTaskGroup(of: (String, LicenseValidationResult?).self) { group in
            for key in keys {
                group.addTask {
                    let result = try? await self.validate(licenseKey: key)
                    return (key, result)
                }
            }
            
            var results: [String: LicenseValidationResult] = [:]
            for await (key, result) in group {
                if let result = result {
                    results[key] = result
                }
            }
            return results
        }
    }
}
```

## Error Handling

### Network-Specific Errors

```swift
func handleLicenseError(_ error: Error) {
    switch error {
    case let apiError as APIError:
        switch apiError.status {
        case 0:
            showOfflineMessage()
        case 429:
            showRateLimitMessage()
        case 502...504:
            showServerMaintenanceMessage()
        default:
            showGenericError(apiError.message)
        }
    case is URLError:
        showNetworkError()
    default:
        showGenericError(error.localizedDescription)
    }
}
```

### Retry Exhaustion

```swift
licenseSeat.on("validation:error") { data in
    if let error = data["error"] as? APIError,
       error.message.contains("after") && error.message.contains("retries") {
        // All retries exhausted
        showPersistentNetworkError()
    }
}
```

## Performance Optimization

### Connection Pooling

The SDK reuses HTTP connections automatically through URLSession.

### Request Deduplication

```swift
// Prevent duplicate requests
class ValidationCoordinator {
    private var inFlightValidations: [String: Task<LicenseValidationResult, Error>] = [:]
    
    func validate(licenseKey: String) async throws -> LicenseValidationResult {
        if let existing = inFlightValidations[licenseKey] {
            return try await existing.value
        }
        
        let task = Task {
            try await LicenseSeat.shared.validate(licenseKey: licenseKey)
        }
        
        inFlightValidations[licenseKey] = task
        defer { inFlightValidations[licenseKey] = nil }
        
        return try await task.value
    }
}
```

## Testing Network Scenarios

### Simulating Network Conditions

```swift
#if DEBUG
// Use Network Link Conditioner on macOS/iOS
// Or inject custom URLSession for testing:

let config = URLSessionConfiguration.ephemeral
config.protocolClasses = [MockURLProtocol.self]
let session = URLSession(configuration: config)

let sdk = LicenseSeat(
    config: .default,
    urlSession: session
)
#endif
```

### Testing Offline Mode

```swift
func testOfflineFallback() async throws {
    // 1. Activate license online
    let license = try await sdk.activate(licenseKey: "TEST")
    
    // 2. Simulate network failure
    MockURLProtocol.requestHandler = { _ in
        throw URLError(.notConnectedToInternet)
    }
    
    // 3. Validation should still work via offline
    let result = try await sdk.validate(licenseKey: "TEST")
    XCTAssertTrue(result.offline)
    XCTAssertTrue(result.valid)
} 