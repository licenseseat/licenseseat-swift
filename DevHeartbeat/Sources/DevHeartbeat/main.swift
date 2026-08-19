/// DevHeartbeat - Development tool to keep a LicenseSeat license activated
///
/// This script activates a license and sends periodic heartbeats to the server,
/// useful for development/testing to generate telemetry data and keep a seat active.
///
/// ## Usage
///
/// From the DevHeartbeat directory:
///
/// ```bash
/// cd /Users/javi/GitHub/licenseseat-swift/DevHeartbeat
///
/// LICENSESEAT_API_KEY="pk_test_xxx" \
/// LICENSESEAT_PRODUCT_SLUG="my-product" \
/// LICENSESEAT_LICENSE_KEY="XXXXX-XXXXX-XXXXX-XXXXX" \
/// swift run
/// ```
///
/// ## Environment Variables
///
/// Required:
///   - LICENSESEAT_API_KEY:      Your publishable API key (pk_test_xxx or pk_live_xxx)
///   - LICENSESEAT_PRODUCT_SLUG: Product slug from the dashboard
///   - LICENSESEAT_LICENSE_KEY:  License key to activate
///
/// Optional:
///   - LICENSESEAT_API_URL:      API endpoint (default: http://localhost:3000/api/v1)
///   - HEARTBEAT_INTERVAL:       Seconds between heartbeats (default: 30)
///
/// ## Behavior
///
/// 1. Activates the license (or reuses existing activation)
/// 2. Validates the license once
/// 3. Sends heartbeats every HEARTBEAT_INTERVAL seconds
/// 4. Runs until Ctrl+C (does NOT deactivate on exit)
///
/// ## Example with all options
///
/// ```bash
/// LICENSESEAT_API_URL="http://localhost:3000/api/v1" \
/// LICENSESEAT_API_KEY="pk_test_3AoX6v69BkqBKeoNTxSLtH6fFEAdmUdwK" \
/// LICENSESEAT_PRODUCT_SLUG="producty" \
/// LICENSESEAT_LICENSE_KEY="VKNGK-FEFHN-KR87H-MQ4SE" \
/// HEARTBEAT_INTERVAL=15 \
/// swift run
/// ```

import Foundation
import LicenseSeat

// MARK: - Configuration (from environment variables)
let API_URL = ProcessInfo.processInfo.environment["LICENSESEAT_API_URL"] ?? "http://localhost:3000/api/v1"
let API_KEY = ProcessInfo.processInfo.environment["LICENSESEAT_API_KEY"] ?? ""
let PRODUCT_SLUG = ProcessInfo.processInfo.environment["LICENSESEAT_PRODUCT_SLUG"] ?? ""
let LICENSE_KEY = ProcessInfo.processInfo.environment["LICENSESEAT_LICENSE_KEY"] ?? ""
let HEARTBEAT_INTERVAL = Double(ProcessInfo.processInfo.environment["HEARTBEAT_INTERVAL"] ?? "30") ?? 30

@main
struct DevHeartbeat {
    static func main() async {
        // Force unbuffered stdout for immediate output
        setbuf(stdout, nil)

        guard !API_KEY.isEmpty, !PRODUCT_SLUG.isEmpty, !LICENSE_KEY.isEmpty else {
            print("""

            DevHeartbeat - Keep a license activated with periodic heartbeats

            Usage:
              LICENSESEAT_API_KEY=pk_test_xxx \\
              LICENSESEAT_PRODUCT_SLUG=my-product \\
              LICENSESEAT_LICENSE_KEY=XXXXX-XXXXX-XXXXX-XXXXX \\
              swift run

            Optional:
              LICENSESEAT_API_URL=http://localhost:3000/api/v1  (default)
              HEARTBEAT_INTERVAL=30                              (seconds, default: 30)

            """)
            return
        }

        print("""

        ╔══════════════════════════════════════════════════════════════╗
        ║                    DevHeartbeat Running                      ║
        ╚══════════════════════════════════════════════════════════════╝

        API URL:    \(API_URL)
        Product:    \(PRODUCT_SLUG)
        License:    \(LICENSE_KEY.prefix(10))...
        Heartbeat:  every \(Int(HEARTBEAT_INTERVAL))s

        Press Ctrl+C to stop (license stays activated)

        """)

        let config = LicenseSeatConfig(
            apiBaseUrl: API_URL,
            apiKey: API_KEY,
            productSlug: PRODUCT_SLUG,
            storagePrefix: "dev_heartbeat_",
            autoValidateInterval: 0,
            heartbeatInterval: 0,  // We'll manage heartbeats manually
            debug: false
        )
        let sdk = LicenseSeat(config: config)

        // Activate or reuse existing
        print("→ Activating license...")
        do {
            let license = try await sdk.activate(licenseKey: LICENSE_KEY)
            print("✓ Activated: device=\(license.deviceId.prefix(20))...")
        } catch let error as APIError {
            if error.code == "already_activated" {
                print("✓ Already activated (reusing seat)")
            } else {
                print("✗ Activation failed: \(error.code ?? "unknown") - \(error.message)")
                return
            }
        } catch {
            print("✗ Activation error: \(error)")
            return
        }

        // Initial validation
        print("→ Validating...")
        do {
            let result = try await sdk.validate(licenseKey: LICENSE_KEY)
            if result.valid {
                print("✓ Valid: plan=\(result.license.planKey), seats=\(result.license.activeSeats)/\(result.license.seatLimit ?? 0)")
            } else {
                print("✗ Invalid license")
                return
            }
        } catch {
            print("✗ Validation error: \(error)")
            return
        }

        print("\n─────────────────────────────────────────────────────────────────")
        print("Heartbeat loop started...\n")

        var heartbeatCount = 0
        while true {
            do {
                try await sdk.heartbeat()
                heartbeatCount += 1
                let timestamp = ISO8601DateFormatter().string(from: Date())
                print("♥ [\(timestamp)] Heartbeat #\(heartbeatCount) sent")
            } catch {
                print("✗ Heartbeat failed: \(error)")
            }

            try? await Task.sleep(nanoseconds: UInt64(HEARTBEAT_INTERVAL * 1_000_000_000))
        }
    }
}
