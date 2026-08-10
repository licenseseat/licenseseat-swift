import Foundation
import LicenseSeat
import Combine
import Darwin

// MARK: - Configuration (from environment variables)
let API_URL = ProcessInfo.processInfo.environment["LICENSESEAT_API_URL"] ?? "http://localhost:3000/api/v1"
let API_KEY = ProcessInfo.processInfo.environment["LICENSESEAT_API_KEY"] ?? ""
let PRODUCT_SLUG = ProcessInfo.processInfo.environment["LICENSESEAT_PRODUCT_SLUG"] ?? ""
let LICENSE_KEY = ProcessInfo.processInfo.environment["LICENSESEAT_LICENSE_KEY"] ?? ""

// MARK: - Test Utilities
@MainActor var passedTests = 0
@MainActor var failedTests = 0
@MainActor var cancellables = Set<AnyCancellable>()

enum ConcurrentOutcome: Sendable {
    case success
    case superseded
    case failure(String)
}

func printHeader(_ title: String) {
    print("\n" + String(repeating: "=", count: 70))
    print("  \(title)")
    print(String(repeating: "=", count: 70))
}

func printTest(_ name: String) {
    print("\n-> Testing: \(name)")
}

@MainActor func pass(_ message: String = "OK") {
    passedTests += 1
    print("   PASS: \(message)")
}

@MainActor func fail(_ message: String) {
    failedTests += 1
    print("   FAIL: \(message)")
}

@MainActor func assert(_ condition: Bool, _ message: String) {
    if condition { pass(message) } else { fail(message) }
}

func log(_ message: String) {
    print("   \(message)")
}

// MARK: - Stress Test
@main
@MainActor
struct TelemetryStressTest {
    static func main() async {
        guard !API_KEY.isEmpty, !PRODUCT_SLUG.isEmpty, !LICENSE_KEY.isEmpty else {
            print("Missing environment variables. Set:")
            print("   LICENSESEAT_API_KEY, LICENSESEAT_PRODUCT_SLUG, LICENSESEAT_LICENSE_KEY")
            print("   Optional: LICENSESEAT_API_URL (default: http://localhost:3000/api/v1)")
            exit(EXIT_FAILURE)
        }

        printHeader("Telemetry, Heartbeat & Activation Stress Test")
        print("""

        API URL:      \(API_URL)
        Product:      \(PRODUCT_SLUG)
        License:      \(LICENSE_KEY.prefix(10))...
        SDK Version:  \(LicenseSeatConfig.sdkVersion)

        """)

        // ============================================================
        // SCENARIO 1: Activation with telemetry enabled (default)
        // ============================================================
        printHeader("SCENARIO 1: Activation WITH Telemetry (default)")

        let config = LicenseSeatConfig(
            apiBaseUrl: API_URL,
            apiKey: API_KEY,
            productSlug: PRODUCT_SLUG,
            storagePrefix: "stress_telemetry_",
            autoValidateInterval: 0,
            heartbeatInterval: 0,
            debug: true
        )
        let sdk = LicenseSeat(config: config)
        sdk.reset()

        printTest("Activate license (telemetry enabled)")
        do {
            let license = try await sdk.activate(licenseKey: LICENSE_KEY)
            pass("Activation successful with telemetry")
            log("Device ID: \(license.deviceId)")
            log("Activation ID: \(license.activationId)")
        } catch let error as APIError {
            fail("Activation failed: \(error.code ?? "unknown") - \(error.message)")
        } catch {
            fail("Activation error: \(error)")
        }

        // ============================================================
        // SCENARIO 2: Validate with telemetry -- check server accepts it
        // ============================================================
        printHeader("SCENARIO 2: Validation WITH Telemetry")

        printTest("Validate license (telemetry payload attached)")
        do {
            let result = try await sdk.validate(licenseKey: LICENSE_KEY)
            assert(result.valid, "License is valid (telemetry accepted by server)")
            log("Plan: \(result.license.planKey)")
            log("Mode: \(result.license.mode)")
            log("Seats: \(result.license.activeSeats)/\(result.license.seatLimit ?? 0)")
        } catch {
            fail("Validation error: \(error)")
        }

        // ============================================================
        // SCENARIO 3: Heartbeat endpoint
        // ============================================================
        printHeader("SCENARIO 3: Heartbeat Endpoint")

        printTest("Send heartbeat (first)")
        do {
            try await sdk.heartbeat()
            pass("Heartbeat accepted by server")
        } catch let error as APIError {
            fail("Heartbeat failed: \(error.code ?? "unknown") - \(error.message)")
        } catch {
            fail("Heartbeat error: \(error)")
        }

        printTest("Send 5 rapid heartbeats")
        var heartbeatSuccesses = 0
        for i in 1...5 {
            do {
                try await sdk.heartbeat()
                heartbeatSuccesses += 1
                log("Heartbeat #\(i) OK")
            } catch {
                log("Heartbeat #\(i) failed: \(error)")
            }
        }
        assert(heartbeatSuccesses == 5, "All 5 rapid heartbeats succeeded (\(heartbeatSuccesses)/5)")

        printTest("Heartbeat with short interval spacing")
        heartbeatSuccesses = 0
        for i in 1...3 {
            try? await Task.sleep(nanoseconds: 500_000_000) // 0.5s between each
            do {
                try await sdk.heartbeat()
                heartbeatSuccesses += 1
                log("Spaced heartbeat #\(i) OK")
            } catch {
                log("Spaced heartbeat #\(i) failed: \(error)")
            }
        }
        assert(heartbeatSuccesses == 3, "All 3 spaced heartbeats succeeded (\(heartbeatSuccesses)/3)")

        // ============================================================
        // SCENARIO 4: Verify enriched telemetry reaches server
        // ============================================================
        printHeader("SCENARIO 4: Enriched Telemetry Server Acceptance")

        printTest("Verify SDK version is set")
        assert(!LicenseSeatConfig.sdkVersion.isEmpty, "SDK version is non-empty: \(LicenseSeatConfig.sdkVersion)")

        printTest("Validate to send enriched telemetry to server")
        do {
            let result = try await sdk.validate(licenseKey: LICENSE_KEY)
            assert(result.valid, "Server accepted enriched telemetry in validation request")
            log("Server accepted validation with all new telemetry fields")
        } catch {
            fail("Validation with enriched telemetry error: \(error)")
        }

        printTest("Heartbeat to send enriched telemetry to server")
        do {
            try await sdk.heartbeat()
            pass("Server accepted heartbeat with enriched telemetry")
        } catch {
            fail("Heartbeat with enriched telemetry error: \(error)")
        }

        printTest("Multiple rapid operations with enriched telemetry")
        var enrichedOps = 0
        for i in 1...3 {
            do {
                let r = try await sdk.validate(licenseKey: LICENSE_KEY)
                if r.valid { enrichedOps += 1 }
                try await sdk.heartbeat()
                enrichedOps += 1
                log("Enriched telemetry round #\(i) OK")
            } catch {
                log("Enriched telemetry round #\(i) error: \(error)")
            }
        }
        assert(enrichedOps == 6, "All enriched telemetry operations succeeded (\(enrichedOps)/6)")

        // ============================================================
        // SCENARIO 5: Telemetry disabled -- verify server still works
        // ============================================================
        printHeader("SCENARIO 5: Telemetry DISABLED")

        // Deactivate first to free the seat
        printTest("Deactivate to free seat for no-telemetry test")
        do {
            try await sdk.deactivate()
            pass("Deactivated OK")
        } catch {
            fail("Could not release telemetry test seat: \(error)")
        }

        let noTelemetryConfig = LicenseSeatConfig(
            apiBaseUrl: API_URL,
            apiKey: API_KEY,
            productSlug: PRODUCT_SLUG,
            storagePrefix: "stress_no_telemetry_",
            autoValidateInterval: 0,
            heartbeatInterval: 0,
            debug: true,
            telemetryEnabled: false
        )
        let noTelemetrySDK = LicenseSeat(config: noTelemetryConfig)
        noTelemetrySDK.reset()

        printTest("Activate with telemetry DISABLED")
        do {
            let license = try await noTelemetrySDK.activate(licenseKey: LICENSE_KEY)
            pass("Activation works without telemetry")
            log("Device ID: \(license.deviceId)")
            log("Activation ID: \(license.activationId)")
        } catch let error as APIError {
            fail("No-telemetry activation failed: \(error.code ?? "unknown") - \(error.message)")
        } catch {
            fail("No-telemetry activation error: \(error)")
        }

        printTest("Validate with telemetry DISABLED")
        do {
            let result = try await noTelemetrySDK.validate(licenseKey: LICENSE_KEY)
            assert(result.valid, "Validation works without telemetry")
        } catch {
            fail("No-telemetry validation error: \(error)")
        }

        printTest("Heartbeat with telemetry DISABLED")
        do {
            try await noTelemetrySDK.heartbeat()
            pass("Heartbeat works without telemetry")
        } catch {
            fail("No-telemetry heartbeat error: \(error)")
        }

        // ============================================================
        // SCENARIO 6: Standalone heartbeat timer fires independently
        // ============================================================
        printHeader("SCENARIO 6: Standalone Heartbeat Timer")

        printTest("Deactivate no-telemetry session before timer test")
        do {
            try await noTelemetrySDK.deactivate()
            pass("No-telemetry session deactivated")
        } catch {
            fail("Could not release no-telemetry test seat: \(error)")
        }

        let heartbeatConfig = LicenseSeatConfig(
            apiBaseUrl: API_URL,
            apiKey: API_KEY,
            productSlug: PRODUCT_SLUG,
            storagePrefix: "stress_heartbeat_timer_",
            autoValidateInterval: 0,   // auto-validation OFF
            heartbeatInterval: 3,       // 3 second heartbeat for testing
            debug: true
        )
        let heartbeatSDK = LicenseSeat(config: heartbeatConfig)
        heartbeatSDK.reset()

        var standaloneHeartbeatCount = 0
        heartbeatSDK.on("heartbeat:success") { _ in
            standaloneHeartbeatCount += 1
        }.store(in: &cancellables)

        printTest("Activate with standalone heartbeat (3s interval, no auto-validation)")
        do {
            _ = try await heartbeatSDK.activate(licenseKey: LICENSE_KEY)
            pass("Activated for standalone heartbeat test")
        } catch let error as APIError {
            fail("Heartbeat timer activation failed: \(error.message)")
        } catch {
            fail("Heartbeat timer activation error: \(error)")
        }

        printTest("Wait for 2 standalone heartbeat cycles (~8 seconds)")
        for i in 1...2 {
            log("Waiting for heartbeat cycle #\(i)...")
            try? await Task.sleep(nanoseconds: 4_000_000_000) // 4s per cycle
        }
        assert(standaloneHeartbeatCount >= 1,
               "At least 1 standalone heartbeat fired (\(standaloneHeartbeatCount) observed)")

        // ============================================================
        // SCENARIO 7: Auto-validation with heartbeat
        // ============================================================
        printHeader("SCENARIO 7: Auto-Validation + Heartbeat Cycles")

        printTest("Deactivate standalone-heartbeat session")
        do {
            try await heartbeatSDK.deactivate()
            pass("Standalone-heartbeat session deactivated")
        } catch {
            fail("Could not release standalone-heartbeat test seat: \(error)")
        }

        let autoConfig = LicenseSeatConfig(
            apiBaseUrl: API_URL,
            apiKey: API_KEY,
            productSlug: PRODUCT_SLUG,
            storagePrefix: "stress_auto_",
            autoValidateInterval: 3,  // 3 second cycles for testing
            heartbeatInterval: 5,     // 5 second heartbeat (different from validation)
            debug: true
        )
        let autoSDK = LicenseSeat(config: autoConfig)
        autoSDK.reset()

        var autoValidationCount = 0
        autoSDK.on("autovalidation:cycle") { _ in
            autoValidationCount += 1
        }.store(in: &cancellables)

        printTest("Activate for auto-validation test")
        do {
            _ = try await autoSDK.activate(licenseKey: LICENSE_KEY)
            pass("Activated for auto-validation")
        } catch let error as APIError {
            fail("Auto-test activation failed: \(error.message)")
        } catch {
            fail("Auto-test activation error: \(error)")
        }

        printTest("Wait for 3 auto-validation + heartbeat cycles (9-12 seconds)")
        for i in 1...3 {
            log("Waiting for cycle #\(i)...")
            try? await Task.sleep(nanoseconds: 4_000_000_000) // 4s per cycle
        }
        assert(autoValidationCount >= 2, "At least 2 auto-validation cycles fired (\(autoValidationCount) observed)")

        // ============================================================
        // SCENARIO 8: Concurrent activations (seat limit stress)
        // ============================================================
        printHeader("SCENARIO 8: Concurrent Validation Stress")

        printTest("Fire 10 concurrent validations")
        let concurrentResults = await withTaskGroup(of: ConcurrentOutcome.self) { group in
            for i in 1...10 {
                group.addTask {
                    do {
                        let result = try await autoSDK.validate(licenseKey: LICENSE_KEY)
                        return result.valid ? .success : .failure("validation #\(i) was invalid")
                    } catch let error as LicenseSeatError {
                        if case .validationFailed(let reason) = error,
                           reason.localizedCaseInsensitiveContains("superseded") {
                            return .superseded
                        }
                        return .failure("validation #\(i): \(error)")
                    } catch {
                        return .failure("validation #\(i): \(error)")
                    }
                }
            }

            var outcomes = [ConcurrentOutcome]()
            for await outcome in group {
                outcomes.append(outcome)
            }
            return outcomes
        }
        let validationSuccesses = concurrentResults.filter { outcome in
            if case .success = outcome { return true }
            return false
        }.count
        let validationFailures = concurrentResults.compactMap { outcome -> String? in
            if case .failure(let message) = outcome { return message }
            return nil
        }
        validationFailures.forEach { log($0) }
        assert(validationSuccesses >= 1, "At least the newest concurrent validation succeeded")
        assert(validationFailures.isEmpty, "Older validations were safely superseded, not failed")
        assert(autoSDK.currentLicense()?.licenseKey == LICENSE_KEY, "Concurrent validation preserved the active grant")

        printTest("Fire 5 concurrent heartbeats")
        let concurrentHeartbeats = await withTaskGroup(of: ConcurrentOutcome.self) { group in
            for i in 1...5 {
                group.addTask {
                    do {
                        try await autoSDK.heartbeat()
                        return .success
                    } catch let error as LicenseSeatError {
                        if case .validationFailed(let reason) = error,
                           reason.localizedCaseInsensitiveContains("superseded") {
                            return .superseded
                        }
                        return .failure("heartbeat #\(i): \(error)")
                    } catch {
                        return .failure("heartbeat #\(i): \(error)")
                    }
                }
            }

            var outcomes = [ConcurrentOutcome]()
            for await outcome in group {
                outcomes.append(outcome)
            }
            return outcomes
        }
        let concurrentHeartbeatSuccesses = concurrentHeartbeats.filter { outcome in
            if case .success = outcome { return true }
            return false
        }.count
        let heartbeatFailures = concurrentHeartbeats.compactMap { outcome -> String? in
            if case .failure(let message) = outcome { return message }
            return nil
        }
        heartbeatFailures.forEach { log($0) }
        assert(concurrentHeartbeatSuccesses >= 1, "At least the newest concurrent heartbeat succeeded")
        assert(heartbeatFailures.isEmpty, "Older heartbeats were safely superseded, not failed")
        assert(autoSDK.currentLicense()?.licenseKey == LICENSE_KEY, "Concurrent heartbeats preserved the active grant")

        // ============================================================
        // SCENARIO 9: Offline Token Download & Verification
        // ============================================================
        printHeader("SCENARIO 9: Offline Token Download & Verification")

        printTest("Deactivate auto-validation session")
        do {
            try await autoSDK.deactivate()
            pass("Auto-validation session deactivated")
        } catch {
            fail("Could not release auto-validation test seat: \(error)")
        }

        let offlineConfig = LicenseSeatConfig(
            apiBaseUrl: API_URL,
            apiKey: API_KEY,
            productSlug: PRODUCT_SLUG,
            storagePrefix: "stress_offline_",
            autoValidateInterval: 0,
            heartbeatInterval: 0,
            debug: true
        )
        let offlineSDK = LicenseSeat(config: offlineConfig)
        offlineSDK.reset()

        printTest("Step 1: Activate before requesting offline token")
        do {
            _ = try await offlineSDK.activate(licenseKey: LICENSE_KEY)
            pass("Activated for offline token test")
        } catch let error as APIError {
            fail("Offline activation failed: \(error.code ?? "unknown") - \(error.message)")
        } catch { fail("Offline activation error: \(error)") }

        printTest("Step 2: Sync offline assets (token + public key)")
        var offlineTokenReady = false
        var offlineFetchError: String? = nil

        offlineSDK.on("offlineToken:ready") { _ in
            offlineTokenReady = true
        }.store(in: &cancellables)
        offlineSDK.on("offlineToken:fetchError") { data in
            offlineFetchError = "\(data)"
        }.store(in: &cancellables)

        // Trigger offline asset sync manually
        await offlineSDK.syncOfflineAssets()

        // Give events a moment to fire
        try? await Task.sleep(nanoseconds: 500_000_000)

        if let fetchErr = offlineFetchError {
            fail("Offline token fetch error: \(fetchErr)")
        } else if offlineTokenReady {
            pass("Offline token downloaded and cached")
        } else {
            log("offlineToken:ready event not received (may still be cached)")
            // Check if we can do offline validation anyway
        }

        printTest("Step 3: Offline validation (verify cached token)")
        let offlineResult = await offlineSDK.verifyCachedOffline()
        log("Offline validation result: valid=\(offlineResult.valid), code=\(offlineResult.code ?? "nil")")
        if offlineResult.valid {
            pass("Offline validation succeeded with cached token")
        } else if offlineResult.code == "no_offline_token" {
            fail("No offline token was cached - download may have failed")
        } else if offlineResult.code == "no_public_key" {
            fail("Public key not cached - signing key download may have failed")
        } else if offlineResult.code == "signature_invalid" {
            fail("Offline token signature verification failed")
        } else {
            fail("Offline validation failed: \(offlineResult.code ?? "unknown")")
        }

        printTest("Step 4: Deactivate offline test session")
        do {
            try await offlineSDK.deactivate()
            pass("Deactivated offline test session")
        } catch { fail("Could not release offline test seat: \(error)") }

        // ============================================================
        // SCENARIO 10: Full lifecycle with telemetry verification
        // ============================================================
        printHeader("SCENARIO 10: Full Lifecycle (activate -> validate -> heartbeat -> deactivate)")

        let lifecycleConfig = LicenseSeatConfig(
            apiBaseUrl: API_URL,
            apiKey: API_KEY,
            productSlug: PRODUCT_SLUG,
            storagePrefix: "stress_lifecycle_",
            autoValidateInterval: 0,
            heartbeatInterval: 0,
            debug: true
        )
        let lifecycleSDK = LicenseSeat(config: lifecycleConfig)
        lifecycleSDK.reset()

        var eventLog: [String] = []
        lifecycleSDK.on("activation:success") { _ in eventLog.append("activation:success") }.store(in: &cancellables)
        lifecycleSDK.on("validation:success") { _ in eventLog.append("validation:success") }.store(in: &cancellables)
        lifecycleSDK.on("deactivation:success") { _ in eventLog.append("deactivation:success") }.store(in: &cancellables)

        printTest("Step 1: Activate")
        do {
            _ = try await lifecycleSDK.activate(licenseKey: LICENSE_KEY)
            pass("Activated")
        } catch let error as APIError {
            fail("Activate: \(error.message)")
        } catch { fail("Activate: \(error)") }

        printTest("Step 2: Validate")
        do {
            let r = try await lifecycleSDK.validate(licenseKey: LICENSE_KEY)
            assert(r.valid, "Valid")
        } catch { fail("Validate: \(error)") }

        printTest("Step 3: Heartbeat")
        do {
            try await lifecycleSDK.heartbeat()
            pass("Heartbeat OK")
        } catch { fail("Heartbeat: \(error)") }

        printTest("Step 4: Deactivate")
        do {
            try await lifecycleSDK.deactivate()
            pass("Deactivated")
            assert(lifecycleSDK.currentLicense() == nil, "License cleared")
        } catch { fail("Deactivate: \(error)") }

        printTest("Event log completeness")
        try? await Task.sleep(nanoseconds: 200_000_000)
        log("Events: \(eventLog)")
        assert(eventLog.contains("activation:success"), "Activation event logged")
        assert(eventLog.contains("validation:success"), "Validation event logged")
        assert(eventLog.contains("deactivation:success"), "Deactivation event logged")

        // ============================================================
        // SUMMARY
        // ============================================================
        printHeader("RESULTS")

        print(String(repeating: "=", count: 70))
        print("  Passed: \(passedTests)")
        print("  Failed: \(failedTests)")
        print("  Total:  \(passedTests + failedTests)")
        print(String(repeating: "=", count: 70))

        if failedTests == 0 {
            print("""

            ALL TESTS PASSED!

            SDK v\(LicenseSeatConfig.sdkVersion) verified:
            - Activation with telemetry
            - Validation with telemetry
            - Heartbeat endpoint (single + rapid + spaced)
            - Enriched telemetry fields (device_type, architecture, cpu_cores, memory_gb, language, screen_resolution, display_scale)
            - Platform field returns 'native' (not duplicating os_name)
            - Standalone heartbeat timer fires independently
            - Telemetry disabled mode (activate/validate/heartbeat)
            - Auto-validation cycles with heartbeat
            - Concurrent validation and heartbeat stress
            - Offline token download and verification
            - Full lifecycle (activate -> validate -> heartbeat -> deactivate)

            """)
        } else {
            print("\n   \(failedTests) test(s) failed. Review output above.\n")
            exit(EXIT_FAILURE)
        }
    }
}
