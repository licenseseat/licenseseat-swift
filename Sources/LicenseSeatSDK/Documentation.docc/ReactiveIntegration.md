# Reactive Integration

Bind LicenseSeat state to Combine, SwiftUI, AppKit, or UIKit without duplicating licensing policy in the UI layer.

## Status Publisher

The status publisher emits license-state transitions and removes duplicates:

```swift
import Combine
import LicenseSeat

@MainActor
final class LicenseViewModel: ObservableObject {
    @Published private(set) var status = LicenseStatus.inactive(message: "Starting")
    private var cancellables = Set<AnyCancellable>()

    init() {
        status = LicenseSeat.shared.getStatus()

        LicenseSeat.statusPublisher
            .sink { [weak self] status in
                self?.status = status
            }
            .store(in: &cancellables)
    }
}
```

Read the current value before subscribing because this publisher represents transitions rather than a `CurrentValueSubject`.

Treat `.active` and `.offlineValid` as licensed:

```swift
var isLicensed: Bool {
    switch status {
    case .active, .offlineValid:
        return true
    default:
        return false
    }
}
```

## Entitlement Publisher

```swift
LicenseSeat.shared.entitlementPublisher(for: "export")
    .map(\.active)
    .removeDuplicates()
    .sink { canExport in
        exportButton.isEnabled = canExport
    }
    .store(in: &cancellables)
```

The store convenience publisher prepends the current entitlement value:

```swift
LicenseSeatStore.shared.entitlementPublisher(for: "export")
    .sink { status in
        canExport = status.active
    }
    .store(in: &cancellables)
```

Entitlement evaluation always checks the parent validation's `valid` flag and the entitlement's own expiry.

## Event Publishers

Use a filtered publisher for one event:

```swift
LicenseSeat.shared.eventPublisher(for: "validation:error")
    .sink { event in
        if let error = event.error {
            logger.error("Validation failed: \(error.localizedDescription)")
        }
    }
    .store(in: &cancellables)
```

Use the all-events publisher for diagnostics or analytics:

```swift
LicenseSeat.shared.eventPublisher
    .sink { event in
        analytics.record(event.name)
    }
    .store(in: &cancellables)
```

The all-events publisher does not depend on a hard-coded event-name mirror; future SDK events flow through automatically.

## Connectivity

```swift
LicenseSeat.shared.networkStatusPublisher
    .sink { [weak self] isOnline in
        self?.showsOfflineBanner = !isOnline
    }
    .store(in: &cancellables)
```

Connectivity is presentation state, not authorization state. Continue to gate features from ``LicenseStatus`` and ``EntitlementStatus``.

## SwiftUI Property Wrappers

Configure the canonical store or static SDK before constructing views:

```swift
@main
struct MyApp: App {
    init() {
        LicenseSeat.configure(
            apiKey: "pk_live_…",
            productSlug: "my-product"
        )
    }

    var body: some Scene {
        WindowGroup { ContentView() }
    }
}
```

Static configuration binds ``LicenseSeatStore/shared`` to the same instance, so property wrappers observe static activation calls:

```swift
struct ContentView: View {
    @LicenseState private var status
    @EntitlementState("export") private var canExport

    var body: some View {
        Group {
            switch status {
            case .active, .offlineValid:
                MainView(canExport: canExport)
            case .pending:
                ProgressView("Checking license…")
            default:
                ActivationView()
            }
        }
    }
}
```

## Activation View Model

```swift
@MainActor
final class ActivationViewModel: ObservableObject {
    @Published var licenseKey = ""
    @Published private(set) var isActivating = false
    @Published private(set) var errorMessage: String?

    func activate() async {
        guard !licenseKey.isEmpty else { return }

        isActivating = true
        defer { isActivating = false }

        do {
            _ = try await LicenseSeat.activate(licenseKey)
            errorMessage = nil
        } catch let error as APIError {
            errorMessage = error.message
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
```

Do not debounce or pre-validate a license key by repeatedly calling the production API while the user types. Submit an explicit activation action.

## Main-Actor Contract

``LicenseSeat`` and ``LicenseSeatStore`` are main-actor isolated. UI code naturally satisfies this contract. Background work should cross explicitly:

```swift
let status = await MainActor.run {
    LicenseSeat.shared.getStatus()
}
```

Event handlers and Combine event delivery occur on the main queue. Avoid blocking handlers; start asynchronous work when necessary.

## Testing Reactive State

Use expectations tied to semantic states, not fixed sleeps:

```swift
func testActivationPublishesActive() async throws {
    let active = expectation(description: "active status")
    let cancellable = LicenseSeat.statusPublisher
        .first { status in
            if case .active = status { return true }
            return false
        }
        .sink { _ in active.fulfill() }

    _ = try await LicenseSeat.activate("TEST-KEY")
    await fulfillment(of: [active], timeout: 2)
    cancellable.cancel()
}
```

Inject a URLSession backed by URLProtocol for deterministic network tests and use unique storage prefixes so persisted state cannot leak between tests.
