# Reactive Integration

Build reactive UIs with Combine publishers and SwiftUI integration.

## Overview

LicenseSeatSDK provides first-class Combine support with built-in publishers for all major events. This enables reactive programming patterns, seamless SwiftUI integration, and declarative UI updates based on license state changes.

## Core Publishers

### Status Publisher

Monitor license status changes in real-time:

```swift
import Combine

let cancellable = licenseSeat.statusPublisher
    .sink { status in
        switch status {
        case .active(let details):
            enableFullFeatures()
        case .inactive:
            showActivationScreen()
        case .invalid:
            showErrorScreen()
        default:
            break
        }
    }
```

### Network Status Publisher

React to connectivity changes:

```swift
licenseSeat.networkStatusPublisher
    .removeDuplicates()
    .sink { isOnline in
        updateConnectionIndicator(online: isOnline)
    }
    .store(in: &cancellables)
```

### Event Publisher

Subscribe to specific SDK events:

```swift
// All events
licenseSeat.eventPublisher
    .filter { $0.name.hasPrefix("validation:") }
    .sink { event in
        logValidationEvent(event)
    }
    .store(in: &cancellables)

// Specific event
licenseSeat.eventPublisher(for: "activation:success")
    .sink { event in
        showSuccessMessage()
    }
    .store(in: &cancellables)
```

### Entitlement Publisher

Monitor specific feature access:

```swift
licenseSeat.entitlementPublisher(for: "premium-features")
    .map { $0.active }
    .removeDuplicates()
    .sink { hasAccess in
        premiumButton.isEnabled = hasAccess
    }
    .store(in: &cancellables)
```

## SwiftUI Integration

### ObservableObject ViewModel

```swift
@MainActor
class LicenseViewModel: ObservableObject {
    @Published var status: LicenseStatus = .inactive(message: "No license")
    @Published var isOnline = true
    @Published var isValidating = false
    @Published var entitlements: Set<String> = []
    
    private let sdk = LicenseSeat.shared
    private var cancellables = Set<AnyCancellable>()
    
    init() {
        // Bind status
        sdk.statusPublisher
            .receive(on: DispatchQueue.main)
            .assign(to: &$status)
        
        // Bind network status
        sdk.networkStatusPublisher
            .receive(on: DispatchQueue.main)
            .assign(to: &$isOnline)
        
        // Track validation state
        sdk.eventPublisher(for: "validation:start")
            .map { _ in true }
            .receive(on: DispatchQueue.main)
            .assign(to: &$isValidating)
        
        sdk.eventPublisher
            .filter { ["validation:success", "validation:failed", "validation:error"].contains($0.name) }
            .map { _ in false }
            .receive(on: DispatchQueue.main)
            .assign(to: &$isValidating)
        
        // Track active entitlements
        sdk.statusPublisher
            .compactMap { status -> [String]? in
                switch status {
                case .active(let details), .offlineValid(let details):
                    return details.entitlements.map { $0.key }
                default:
                    return nil
                }
            }
            .map { Set($0) }
            .receive(on: DispatchQueue.main)
            .assign(to: &$entitlements)
    }
    
    func activate(licenseKey: String) async {
        do {
            _ = try await sdk.activate(licenseKey: licenseKey)
        } catch {
            // Error handling
        }
    }
    
    func hasEntitlement(_ key: String) -> Bool {
        entitlements.contains(key)
    }
}
```

### SwiftUI Views

```swift
struct LicenseStatusView: View {
    @StateObject private var license = LicenseViewModel()
    
    var body: some View {
        VStack(spacing: 20) {
            // Status indicator
            HStack {
                Circle()
                    .fill(statusColor)
                    .frame(width: 10, height: 10)
                
                Text(statusText)
                    .font(.headline)
                
                if !license.isOnline {
                    Label("Offline", systemImage: "wifi.slash")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            
            // Validation progress
            if license.isValidating {
                ProgressView("Validating license...")
            }
            
            // Feature gates
            if license.hasEntitlement("premium-features") {
                PremiumFeaturesView()
            } else {
                UpgradePromptView()
            }
        }
        .padding()
    }
    
    private var statusColor: Color {
        switch license.status {
        case .active, .offlineValid:
            return .green
        case .inactive:
            return .gray
        case .invalid, .offlineInvalid:
            return .red
        case .pending:
            return .orange
        }
    }
    
    private var statusText: String {
        switch license.status {
        case .active:
            return "License Active"
        case .offlineValid:
            return "License Valid (Offline)"
        case .inactive:
            return "No License"
        case .invalid:
            return "Invalid License"
        case .offlineInvalid:
            return "Invalid License (Offline)"
        case .pending:
            return "Checking License..."
        }
    }
}
```

### Activation Flow

```swift
struct ActivationView: View {
    @State private var licenseKey = ""
    @State private var isActivating = false
    @State private var error: Error?
    @EnvironmentObject var license: LicenseViewModel
    
    var body: some View {
        Form {
            Section("Enter License Key") {
                TextField("XXXX-XXXX-XXXX-XXXX", text: $licenseKey)
                    .textFieldStyle(.roundedBorder)
                    .disabled(isActivating)
            }
            
            Section {
                Button("Activate") {
                    activate()
                }
                .buttonStyle(.borderedProminent)
                .disabled(licenseKey.isEmpty || isActivating)
                
                if isActivating {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                }
            }
            
            if let error = error {
                Section {
                    Label(error.localizedDescription, systemImage: "exclamationmark.triangle")
                        .foregroundColor(.red)
                }
            }
        }
        .navigationTitle("Activate License")
    }
    
    private func activate() {
        isActivating = true
        error = nil
        
        Task {
            do {
                try await LicenseSeat.shared.activate(licenseKey: licenseKey)
                // Navigation handled by parent based on status change
            } catch {
                self.error = error
            }
            isActivating = false
        }
    }
}
```

## Advanced Patterns

### Debounced Validation

```swift
class DebouncedValidator: ObservableObject {
    @Published var licenseKey = ""
    @Published var validationResult: LicenseValidationResult?
    
    private var cancellables = Set<AnyCancellable>()
    
    init() {
        $licenseKey
            .debounce(for: .seconds(1), scheduler: DispatchQueue.main)
            .removeDuplicates()
            .filter { !$0.isEmpty }
            .sink { [weak self] key in
                Task {
                    self?.validationResult = try? await LicenseSeat.shared.validate(licenseKey: key)
                }
            }
            .store(in: &cancellables)
    }
}
```

### Event Aggregation

```swift
extension LicenseSeat {
    /// Publisher that emits true when any validation is in progress
    var isValidatingPublisher: AnyPublisher<Bool, Never> {
        let start = eventPublisher(for: "validation:start").map { _ in true }
        let end = eventPublisher
            .filter { ["validation:success", "validation:failed", "validation:error"].contains($0.name) }
            .map { _ in false }
        
        return Publishers.Merge(start, end)
            .removeDuplicates()
            .eraseToAnyPublisher()
    }
    
    /// Publisher for validation results
    var validationResultPublisher: AnyPublisher<LicenseValidationResult?, Never> {
        eventPublisher
            .compactMap { event -> LicenseValidationResult? in
                switch event.name {
                case "validation:success", "validation:offline-success":
                    return event.data as? LicenseValidationResult
                default:
                    return nil
                }
            }
            .eraseToAnyPublisher()
    }
}
```

### Reactive Entitlement Checking

```swift
struct FeatureGate<Content: View>: View {
    let entitlement: String
    let content: () -> Content
    let fallback: () -> AnyView
    
    @State private var hasAccess = false
    
    var body: some View {
        Group {
            if hasAccess {
                content()
            } else {
                fallback()
            }
        }
        .onReceive(LicenseSeat.shared.entitlementPublisher(for: entitlement)) { status in
            hasAccess = status.active
        }
    }
}

// Usage
FeatureGate(entitlement: "advanced-analytics") {
    AnalyticsView()
} fallback: {
    AnyView(
        VStack {
            Image(systemName: "chart.line.uptrend.xyaxis")
                .font(.largeTitle)
            Text("Upgrade to Pro for Analytics")
            Button("Upgrade") { showUpgrade() }
        }
    )
}
```

### Offline Mode Indicator

```swift
struct OfflineModeBanner: View {
    @State private var isOffline = false
    @State private var lastSync: Date?
    
    var body: some View {
        if isOffline {
            HStack {
                Image(systemName: "wifi.slash")
                Text("Offline Mode")
                Spacer()
                if let lastSync = lastSync {
                    Text("Last sync: \(lastSync, style: .relative)")
                        .font(.caption)
                }
            }
            .padding()
            .background(Color.orange.opacity(0.2))
            .onReceive(LicenseSeat.shared.networkStatusPublisher) { online in
                isOffline = !online
                if online {
                    lastSync = Date()
                }
            }
        }
    }
}
```

## Testing Reactive Code

### Publisher Testing

```swift
func testStatusPublisherEmitsChanges() async throws {
    let expectation = XCTestExpectation(description: "Status change")
    var receivedStatuses: [LicenseStatus] = []
    
    let cancellable = sdk.statusPublisher
        .sink { status in
            receivedStatuses.append(status)
            if receivedStatuses.count >= 2 {
                expectation.fulfill()
            }
        }
    
    // Activate license
    _ = try await sdk.activate(licenseKey: "TEST-KEY")
    
    wait(for: [expectation], timeout: 5)
    
    XCTAssertTrue(receivedStatuses.contains { status in
        if case .active = status { return true }
        return false
    })
    
    cancellable.cancel()
}
```

### Mock Publisher

```swift
class MockLicenseSeat: LicenseSeat {
    let mockStatusSubject = CurrentValueSubject<LicenseStatus, Never>(.inactive(message: "Mock"))
    
    override var statusPublisher: AnyPublisher<LicenseStatus, Never> {
        mockStatusSubject.eraseToAnyPublisher()
    }
}

// In tests
let mock = MockLicenseSeat()
mock.mockStatusSubject.send(.active(details: testDetails))
```

## Best Practices

1. **Always receive on main queue for UI updates**
2. **Use `removeDuplicates()` to prevent unnecessary updates**
3. **Store cancellables to prevent premature deallocation**
4. **Debounce user input to avoid excessive API calls**
5. **Handle backpressure with operators like `throttle` or `debounce`**
6. **Test publishers with expectations and timeouts**
7. **Use `@Published` properties for SwiftUI binding** 