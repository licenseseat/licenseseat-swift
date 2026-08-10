import Combine
import Darwin
import Foundation
import LicenseSeat

/// Interactive macOS client that exercises the public 0.4.2 SDK surface.
///
/// Required environment variables:
/// - `LICENSESEAT_API_KEY` (a publishable `pk_...` key)
/// - `LICENSESEAT_PRODUCT_SLUG`
///
/// `LICENSESEAT_API_URL` is optional and defaults to the production v1 API.
@main
@MainActor
struct LicenseSeatExample {
    private static var cancellables = Set<AnyCancellable>()

    static func main() async {
        let environment = ProcessInfo.processInfo.environment
        guard let apiKey = environment["LICENSESEAT_API_KEY"], !apiKey.isEmpty,
              let productSlug = environment["LICENSESEAT_PRODUCT_SLUG"], !productSlug.isEmpty
        else {
            print("Set LICENSESEAT_API_KEY and LICENSESEAT_PRODUCT_SLUG before running the example.")
            exit(EXIT_FAILURE)
        }

        let config = LicenseSeatConfig(
            apiBaseUrl: environment["LICENSESEAT_API_URL"]
                ?? LicenseSeatConfig.productionAPIBaseURL,
            apiKey: apiKey,
            productSlug: productSlug,
            autoValidateInterval: 60,
            heartbeatInterval: 300,
            networkRecheckInterval: 2,
            offlineFallbackMode: .networkOnly
        )
        let sdk = LicenseSeat(config: config)

        sdk.statusPublisher
            .sink { status in
                print("\nLicense status changed:")
                printStatus(status)
            }
            .store(in: &cancellables)

        for event in [
            "activation:success",
            "activation:error",
            "validation:success",
            "validation:failed",
            "validation:offline-success",
            "validation:offline-failed",
            "heartbeat:success",
            "heartbeat:error",
            "deactivation:success",
            "license:revoked",
        ] {
            sdk.on(event) { _ in
                // Event payloads can contain license or device identifiers.
                // Demonstrate safe logging by printing only the event name.
                print("\nSDK event: \(event)")
            }.store(in: &cancellables)
        }

        // Initialization verifies protected cached state asynchronously.
        try? await Task.sleep(nanoseconds: 100_000_000)
        print("LicenseSeat SDK \(LicenseSeatConfig.sdkVersion)")
        print("Product: \(productSlug)")
        printStatus(sdk.getStatus())

        await interactiveMenu(sdk: sdk)
    }

    private static func interactiveMenu(sdk: LicenseSeat) async {
        while true {
            print("""

            LicenseSeat Example
            1. Activate license
            2. Validate active license
            3. Send heartbeat
            4. Check entitlement
            5. Show status
            6. Deactivate license
            7. Check API health
            8. Reset local license state
            9. Exit
            """)

            guard let choice = await readInput("Choice: ") else { return }
            switch choice {
            case "1":
                await activateLicense(sdk: sdk)
            case "2":
                await validateLicense(sdk: sdk)
            case "3":
                await sendHeartbeat(sdk: sdk)
            case "4":
                await checkEntitlement(sdk: sdk)
            case "5":
                printStatus(sdk.getStatus())
            case "6":
                await deactivateLicense(sdk: sdk)
            case "7":
                await checkHealth(sdk: sdk)
            case "8":
                sdk.reset()
                print("Local grant state cleared; the installation identifier was retained.")
            case "9":
                return
            default:
                print("Invalid choice")
            }
        }
    }

    private static func activateLicense(sdk: LicenseSeat) async {
        guard let key = await readInput("License key: "), !key.isEmpty else {
            print("A license key is required.")
            return
        }

        do {
            let license = try await sdk.activate(
                licenseKey: key,
                options: ActivationOptions(
                    metadata: ["integration": "LicenseSeatExample"]
                )
            )
            print("Activated \(redactedKey(license.licenseKey)) at \(license.activatedAt).")
        } catch {
            print("Activation failed: \(error.localizedDescription)")
        }
    }

    private static func validateLicense(sdk: LicenseSeat) async {
        guard let license = sdk.currentLicense() else {
            print("No active license to validate.")
            return
        }

        do {
            let result = try await sdk.validate(licenseKey: license.licenseKey)
            print("Valid: \(result.valid)")
            if let code = result.code { print("Code: \(code)") }
            if let message = result.message { print("Message: \(message)") }
            let keys = result.license.activeEntitlements.map(\.key).joined(separator: ", ")
            print("Active entitlements: \(keys.isEmpty ? "none" : keys)")
        } catch {
            print("Validation failed: \(error.localizedDescription)")
        }
    }

    private static func sendHeartbeat(sdk: LicenseSeat) async {
        do {
            try await sdk.heartbeat()
            print("Heartbeat accepted.")
        } catch {
            print("Heartbeat failed: \(error.localizedDescription)")
        }
    }

    private static func checkEntitlement(sdk: LicenseSeat) async {
        guard let key = await readInput("Entitlement key: "), !key.isEmpty else {
            print("An entitlement key is required.")
            return
        }

        let status = sdk.checkEntitlement(key)
        print("Active: \(status.active)")
        if let reason = status.reason { print("Reason: \(reason)") }
        if let expiresAt = status.expiresAt { print("Expires: \(expiresAt)") }
    }

    private static func deactivateLicense(sdk: LicenseSeat) async {
        do {
            try await sdk.deactivate()
            print("License deactivated and local grant state cleared.")
        } catch {
            print("Deactivation failed: \(error.localizedDescription)")
        }
    }

    private static func checkHealth(sdk: LicenseSeat) async {
        do {
            let health = try await sdk.healthCheck()
            print("API status: \(health.status), version: \(health.apiVersion)")
        } catch {
            print("Health check failed: \(error.localizedDescription)")
        }
    }

    private static func printStatus(_ status: LicenseStatus) {
        switch status {
        case let .active(details):
            print("Active: \(redactedKey(details.license)); \(details.entitlements.count) entitlements")
        case let .offlineValid(details):
            print("Offline-valid: \(redactedKey(details.license))")
        case let .inactive(message):
            print("Inactive: \(message)")
        case let .invalid(message):
            print("Invalid: \(message)")
        case let .pending(message):
            print("Pending: \(message)")
        case let .offlineInvalid(message):
            print("Offline-invalid: \(message)")
        }
    }

    private static func redactedKey(_ key: String) -> String {
        String(key.prefix(8)) + "..."
    }

    /// Read stdin on a detached task so main-actor timers and URLSession
    /// callbacks continue to run while the CLI waits at a prompt.
    private static func readInput(_ prompt: String) async -> String? {
        print(prompt, terminator: "")
        fflush(stdout)
        return await Task.detached { readLine() }.value
    }
}
