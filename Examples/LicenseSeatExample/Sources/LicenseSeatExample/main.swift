import Foundation
import LicenseSeat
#if canImport(Combine)
import Combine
#endif

// Example app demonstrating LicenseSeat usage
@main
struct LicenseSeatExample {
    static func main() async {
        print("🚀 LicenseSeat Example")
        print("=======================\n")
        
        // Configure SDK
        var config = LicenseSeatConfig(
            apiBaseUrl: ProcessInfo.processInfo.environment["LICENSESEAT_API_URL"] ?? "https://api.licenseseat.com",
            apiKey: ProcessInfo.processInfo.environment["LICENSESEAT_API_KEY"],
            autoValidateInterval: 60, // 1-minute auto-validation while online
            networkRecheckInterval: 2, // 2-second heartbeat while offline
            debug: true
        )
        
        // Enable strict offline fallback (network/error only)
        config.strictOfflineFallback = true
        
        let sdk = LicenseSeat(config: config)
        
        // Set up event monitoring
        var cancellables = Set<AnyCancellable>()
        
        // Monitor all events
        sdk.eventPublisher
            .sink { event in
                print("📡 Event: \(event.name)")
                if let dict = event.dictionary {
                    print("   Data: \(dict)")
                }
            }
            .store(in: &cancellables)
        
        // Monitor license status
        sdk.statusPublisher
            .sink { status in
                print("\n📋 License Status Changed:")
                switch status {
                case .active(let details):
                    print("   ✅ Active - License: \(details.license)")
                    print("   📅 Activated: \(details.activatedAt)")
                    print("   🎯 Entitlements: \(details.entitlements.count)")
                case .inactive(let message):
                    print("   ❌ Inactive - \(message)")
                case .invalid(let message):
                    print("   ⚠️ Invalid - \(message)")
                case .pending(let message):
                    print("   ⏳ Pending - \(message)")
                case .offlineValid(let details):
                    print("   ✅ Valid (Offline) - License: \(details.license)")
                case .offlineInvalid(let message):
                    print("   ❌ Invalid (Offline) - \(message)")
                }
            }
            .store(in: &cancellables)
        
        // Monitor auto-validation events specifically
        sdk.on("autovalidation:cycle") { data in
            print("\n⏰ AUTO-VALIDATION CYCLE:", data)
            print("Enter choice: ", terminator: "")
            fflush(stdout)
        }.store(in: &cancellables)
        
        sdk.on("validation:success") { data in
            print("\n✅ AUTO-VALIDATION SUCCESS")
            print("Enter choice: ", terminator: "")
            fflush(stdout)
        }.store(in: &cancellables)
        
        sdk.on("validation:auto-failed") { data in
            print("\n❌ AUTO-VALIDATION FAILED:", data)
            print("Enter choice: ", terminator: "")
            fflush(stdout)
        }.store(in: &cancellables)
        
        // Give SDK a moment to initialize and check for cached license
        try? await Task.sleep(nanoseconds: 100_000_000) // 0.1 seconds
        
        // Check current status
        let currentStatus = sdk.getStatus()
        print("📊 Initial SDK Status: \(currentStatus)")
        
        if let license = sdk.currentLicense() {
            print("📄 Found cached license: \(license.licenseKey)")
            print("   Device: \(license.deviceIdentifier)")
            print("   Activated: \(license.activatedAt)")
        } else {
            print("❌ No cached license found - activate one to start auto-validation")
        }
        
        // Run interactive menu directly (blocking). This keeps the process
        // alive until the user chooses to exit.
        await interactiveMenu(sdk: sdk)
    }
    
    // MARK: - Interactive Menu (runs on main actor)

    private static func interactiveMenu(sdk: LicenseSeat) async {
        func menu() {
            print("\n📋 LicenseSeat Example Menu")
            print("1. Activate License")
            print("2. Validate License")
            print("3. Check Entitlement")
            print("4. Show Status")
            print("5. Deactivate License")
            print("6. Test Auth")
            print("7. Reset SDK")
            print("8. Exit")
            print("\nEnter choice: ", terminator: "")
            fflush(stdout)
        }
        while true {
            menu()
            guard let choice = readLine() else { continue }
            switch choice {
            case "1":
                await activateLicense(sdk: sdk)
            case "2":
                await validateLicense(sdk: sdk)
            case "3":
                await checkEntitlement(sdk: sdk)
            case "4":
                await showStatus(sdk: sdk)
            case "5":
                await deactivateLicense(sdk: sdk)
            case "6":
                await testAuth(sdk: sdk)
            case "7":
                await MainActor.run { sdk.reset() }
                print("✅ SDK reset complete")
            case "8":
                print("👋 Goodbye!")
                return
            default:
                print("❌ Invalid choice")
            }
        }
    }
    
    static func activateLicense(sdk: LicenseSeat) async {
        print("\nEnter license key: ", terminator: "")
        guard let key = readLine(), !key.isEmpty else {
            print("❌ Invalid license key")
            return
        }
        
        do {
            let license = try await sdk.activate(
                licenseKey: key,
                options: ActivationOptions(
                    metadata: [
                        "app": "LicenseSeatExample",
                        "version": "1.0.0"
                    ]
                )
            )
            
            print("\n✅ License Activated!")
            print("   License: \(license.licenseKey)")
            print("   Device: \(license.deviceIdentifier)")
            print("   Activated: \(license.activatedAt)")
            
        } catch {
            print("❌ Activation failed: \(error)")
        }
    }
    
    static func validateLicense(sdk: LicenseSeat) async {
        guard let license = await sdk.currentLicense() else {
            print("❌ No active license to validate")
            return
        }
        
        do {
            let result = try await sdk.validate(licenseKey: license.licenseKey)
            
            print("\n✅ Validation Result:")
            print("   Valid: \(result.valid)")
            print("   Offline: \(result.offline)")
            if let reason = result.reason {
                print("   Reason: \(reason)")
            }
            if let entitlements = result.activeEntitlements {
                print("   Active Entitlements: \(entitlements.count)")
                for ent in entitlements {
                    print("     - \(ent.key): \(ent.name ?? "Unnamed")")
                }
            }
            
        } catch {
            print("❌ Validation failed: \(error)")
        }
    }
    
    static func checkEntitlement(sdk: LicenseSeat) async {
        print("\nEnter entitlement key: ", terminator: "")
        guard let key = readLine(), !key.isEmpty else {
            print("❌ Invalid entitlement key")
            return
        }
        
        let status = await sdk.checkEntitlement(key)
        
        print("\n🎯 Entitlement '\(key)':")
        print("   Active: \(status.active)")
        if let reason = status.reason {
            print("   Reason: \(reason)")
        }
        if let expires = status.expiresAt {
            print("   Expires: \(expires)")
        }
        if let entitlement = status.entitlement {
            print("   Name: \(entitlement.name ?? "Unnamed")")
            print("   Description: \(entitlement.description ?? "No description")")
        }
    }
    
    static func showStatus(sdk: LicenseSeat) async {
        let status = await sdk.getStatus()
        
        print("\n📊 Current Status:")
        switch status {
        case .active(let details):
            print("   ✅ Active")
            print("   License: \(details.license)")
            print("   Device: \(details.device)")
            print("   Activated: \(details.activatedAt)")
            print("   Last Validated: \(details.lastValidated)")
            print("   Entitlements: \(details.entitlements.count)")
            
        case .inactive(let message):
            print("   ❌ Inactive: \(message)")
            
        case .invalid(let message):
            print("   ⚠️ Invalid: \(message)")
            
        case .pending(let message):
            print("   ⏳ Pending: \(message)")
            
        case .offlineValid(let details):
            print("   ✅ Valid (Offline)")
            print("   License: \(details.license)")
            
        case .offlineInvalid(let message):
            print("   ❌ Invalid (Offline): \(message)")
        }
    }
    
    static func deactivateLicense(sdk: LicenseSeat) async {
        guard await sdk.currentLicense() != nil else {
            print("❌ No active license to deactivate")
            return
        }
        
        do {
            try await sdk.deactivate()
            print("✅ License deactivated successfully")
        } catch {
            print("❌ Deactivation failed: \(error)")
        }
    }
    
    static func testAuth(sdk: LicenseSeat) async {
        do {
            let result = try await sdk.testAuth()
            print("\n✅ Auth Test:")
            print("   Success: \(result.success)")
            if let message = result.message {
                print("   Message: \(message)")
            }
        } catch {
            print("❌ Auth test failed: \(error)")
        }
    }
} 