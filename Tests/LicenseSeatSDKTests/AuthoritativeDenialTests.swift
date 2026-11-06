//
//  AuthoritativeDenialTests.swift
//  LicenseSeatSDKTests
//
//  An explicit refusal of this app version / product / feature must never be
//  overruled by a signed offline grant (under either fallback mode), and must
//  never purge the license or its grant. Rate limits and auth errors stay
//  eligible for `.always` fallback; revocation still purges.
//

import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(CryptoKit)
import CryptoKit
#elseif canImport(Crypto)
import Crypto
#endif
@testable import LicenseSeat

@MainActor
final class AuthoritativeDenialTests: LicenseSeatTestCase {
    private static let productSlug = "denial-app"
    private static let licenseKey = "DENIAL-KEY-0001"
    private static let deviceId = "denial-device-0001"
    private static let kid = "denial-kid"

    private var sdk: LicenseSeat!
    private var storagePrefix = ""
    private let signingKey = Curve25519.Signing.PrivateKey()

    nonisolated private static func makeMockedSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private func makeSDK(
        mode: LicenseSeatConfig.OfflineFallbackMode = .always,
        appVersion: String = "3.0.1"
    ) -> LicenseSeat {
        LicenseSeat(
            config: LicenseSeatConfig(
                apiBaseUrl: "https://api.test.com",
                apiKey: "pk_test_denial",
                productSlug: Self.productSlug,
                storagePrefix: storagePrefix,
                deviceIdentifier: Self.deviceId,
                autoValidateInterval: 0,
                heartbeatInterval: 0,
                maxRetries: 0,
                appVersion: appVersion,
                offlineFallbackMode: mode
            ),
            urlSession: Self.makeMockedSession()
        )
    }

    override func setUp() async throws {
        _ = URLProtocol.registerClass(MockURLProtocol.self)
        MockURLProtocol.reset()
        MockURLProtocol.requestHandler = { _ in throw URLError(.notConnectedToInternet) }
        storagePrefix = "authoritative_denial_test_\(UUID().uuidString)_"
        sdk = makeSDK()
        sdk.cache.clear()
        try cacheActivationWithValidGrant()
    }

    override func tearDown() {
        MockURLProtocol.reset()
        URLProtocol.unregisterClass(MockURLProtocol.self)
        super.tearDown()
    }

    // MARK: - Fixtures

    private func cacheActivationWithValidGrant() throws {
        XCTAssertTrue(sdk.cache.setLicense(License(
            licenseKey: Self.licenseKey,
            deviceId: Self.deviceId,
            activationId: "act-denial-0001",
            activatedAt: Date(),
            lastValidated: Date()
        )))
        let now = Int(Date().timeIntervalSince1970)
        let payload = OfflineTokenResponse.TokenPayload(
            schemaVersion: 1, licenseKey: Self.licenseKey, productSlug: Self.productSlug,
            planKey: "personal", mode: "hardware_locked", seatLimit: 1, deviceId: Self.deviceId,
            iat: now - 60, exp: now + 30 * 86_400, nbf: now - 60, licenseExpiresAt: nil,
            kid: Self.kid, entitlements: [], metadata: nil
        )
        let canonical = try CanonicalJSON.stringify(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(payload))
        )
        XCTAssertTrue(sdk.cache.setOfflineToken(OfflineTokenResponse(
            object: "offline_token",
            token: payload,
            signature: .init(
                algorithm: "Ed25519",
                keyId: Self.kid,
                value: Base64URL.encode(try signingKey.signature(for: Data(canonical.utf8)))
            ),
            canonical: canonical
        )))
        XCTAssertTrue(sdk.cache.setPublicKey(
            Self.kid,
            Base64URL.encode(signingKey.publicKey.rawRepresentation)
        ))
    }

    private static func validation(
        valid: Bool,
        code: String?,
        ceiling: String? = "3.0.0"
    ) -> [String: Any] {
        [
            "object": "validation_result",
            "valid": valid,
            "code": code as Any? ?? NSNull(),
            "message": code.map { "Refused: \($0)" } as Any? ?? NSNull(),
            "warnings": NSNull(),
            "license": [
                "object": "license",
                "key": licenseKey,
                "status": "active",
                "starts_at": NSNull(),
                "expires_at": NSNull(),
                "mode": "hardware_locked",
                "plan_key": "personal",
                "seat_limit": 1,
                "active_seats": 1,
                "active_entitlements": ceiling.map { ceiling -> [[String: Any]] in [[
                    "key": "updates", "expires_at": NSNull(),
                    "below_version": ceiling, "metadata": NSNull()
                ]] } ?? [],
                "metadata": NSNull(),
                "product": ["slug": productSlug, "name": "Denial App"]
            ],
            "activation": NSNull()
        ]
    }

    private static func respond(
        _ status: Int,
        _ body: Any
    ) -> (URLRequest) throws -> (HTTPURLResponse, Data) {
        { request in
            (
                HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil,
                                headerFields: ["Content-Type": "application/json"])!,
                try JSONSerialization.data(withJSONObject: body)
            )
        }
    }

    private func assertGrantKept(file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertNotNil(sdk.currentLicense(), "license must be kept", file: file, line: line)
        XCTAssertNotNil(sdk.cache.getOfflineToken(), "offline grant must be kept", file: file, line: line)
    }

    private func assertInvalid(file: StaticString = #filePath, line: UInt = #line) {
        guard case .invalid = sdk.getStatus() else {
            return XCTFail("expected .invalid, got \(sdk.getStatus())", file: file, line: line)
        }
    }

    private func relaunch(appVersion: String, mode: LicenseSeatConfig.OfflineFallbackMode = .always) async {
        sdk.shutdown()
        sdk = makeSDK(mode: mode, appVersion: appVersion)
        await sdk.waitForInitialization()
    }

    private func assertNotOfflineValid(_ label: String, file: StaticString = #filePath, line: UInt = #line) async {
        if case .offlineValid = sdk.getStatus() {
            XCTFail("\(label): status is offlineValid", file: file, line: line)
        }
        let explicit = await sdk.verifyCachedOffline()
        XCTAssertFalse(explicit.valid, "\(label): verifyCachedOffline granted", file: file, line: line)
        MockURLProtocol.requestHandler = { _ in throw URLError(.notConnectedToInternet) }
        do {
            _ = try await sdk.validate(licenseKey: Self.licenseKey)
            XCTFail("\(label): an outage fell back to the grant", file: file, line: line)
        } catch {}
    }

    // MARK: - Round 2 (Astra on #26)

    func testRollbackThenUpgradeOfflineStaysDenied() async throws {
        // F1: the rollback launch must not erase the denial.
        MockURLProtocol.requestHandler = Self.respond(200, Self.validation(valid: false, code: "version_not_entitled"))
        _ = try await sdk.validate(licenseKey: Self.licenseKey)

        MockURLProtocol.requestHandler = { _ in throw URLError(.notConnectedToInternet) }
        await relaunch(appVersion: "2.9.0")
        guard case .offlineValid = sdk.getStatus() else {
            return XCTFail("the covered rollback must work offline, got \(sdk.getStatus())")
        }

        await relaunch(appVersion: "3.0.1")
        await assertNotOfflineValid("3.0.1 after rollback")
        assertGrantKept()
    }

    func testALeadingVOnTheDeniedVersionIsNotARollback() async throws {
        // F2: the server strips a leading "v"; "v3.0.1" is the refused version.
        await relaunch(appVersion: "v3.0.1")
        MockURLProtocol.requestHandler = Self.respond(200, Self.validation(valid: false, code: "version_not_entitled"))
        _ = try await sdk.validate(licenseKey: Self.licenseKey)

        await assertNotOfflineValid("same process")
        await relaunch(appVersion: "v3.0.1")
        await assertNotOfflineValid("relaunch")
        XCTAssertEqual(LicenseSeat.serverCoreVersion("v3.0.1"), [3, 0, 1])
        XCTAssertEqual(LicenseSeat.serverCoreVersion(" 3 "), [3, 0, 0])
        XCTAssertNil(LicenseSeat.serverCoreVersion("3.0.99999999999999999999"))
        XCTAssertNil(LicenseSeat.serverCoreVersion("V3.0.1"))
    }

    func testARefusedReactivationIsRecordedAndARevokedOnePurges() async throws {
        // F3: activate's refusals are decisions about the cached activation.
        MockURLProtocol.requestHandler = Self.respond(403, [
            "error": ["code": "version_not_entitled", "message": "Not covered"]
        ])
        do {
            _ = try await sdk.activate(licenseKey: Self.licenseKey)
            XCTFail("expected the refusal")
        } catch {}
        assertInvalid()
        assertGrantKept()
        await assertNotOfflineValid("after refused re-activation")

        MockURLProtocol.requestHandler = Self.respond(422, [
            "error": ["code": "revoked", "message": "Revoked"]
        ])
        do {
            _ = try await sdk.activate(licenseKey: Self.licenseKey)
            XCTFail("expected the revocation")
        } catch {}
        XCTAssertNil(sdk.currentLicense())
        XCTAssertNil(sdk.cache.getOfflineToken())
    }

    func testAThrownDenialIsNotExemptedByAnOlderCeiling() async throws {
        // F4: cached metadata says < 4.0.0; the server now refuses 3.5.0.
        await relaunch(appVersion: "3.5.0")
        MockURLProtocol.requestHandler = Self.respond(200, Self.validation(valid: true, code: nil, ceiling: "4.0.0"))
        _ = try await sdk.validate(licenseKey: Self.licenseKey)

        MockURLProtocol.requestHandler = Self.respond(403, [
            "error": ["code": "version_not_entitled", "message": "Not covered"]
        ])
        do { _ = try await sdk.validate(licenseKey: Self.licenseKey) } catch {}

        await assertNotOfflineValid("3.5.0 with an obsolete 4.0.0 ceiling")
    }

    func testRollingBackToTheLastAcceptedVersionWorksWithoutCeilingEvidence() async throws {
        // F5: thrown denial (no ceiling) and valid:false without an updates
        // entitlement; the version accepted online before is still entitled.
        for thrown in [true, false] {
            sdk.shutdown()
            storagePrefix = "authoritative_denial_test_\(UUID().uuidString)_"
            sdk = makeSDK(appVersion: "2.9.0")
            try cacheActivationWithValidGrant()
            MockURLProtocol.requestHandler = Self.respond(200, Self.validation(valid: true, code: nil, ceiling: nil))
            _ = try await sdk.validate(licenseKey: Self.licenseKey)

            await relaunch(appVersion: "3.0.1")
            MockURLProtocol.requestHandler = thrown
                ? Self.respond(403, ["error": ["code": "version_not_entitled", "message": "Not covered"]])
                : Self.respond(200, Self.validation(valid: false, code: "version_not_entitled", ceiling: nil))
            do { _ = try await sdk.validate(licenseKey: Self.licenseKey) } catch {}
            await assertNotOfflineValid("3.0.1, thrown=\(thrown)")

            MockURLProtocol.requestHandler = { _ in throw URLError(.notConnectedToInternet) }
            await relaunch(appVersion: "2.9.0")
            guard case .offlineValid = sdk.getStatus() else {
                return XCTFail("thrown=\(thrown): rollback to 2.9.0 must work offline, got \(sdk.getStatus())")
            }
        }
    }

    func testSeatLimitExceededIsAnAuthoritativeDenial() async throws {
        // F6, both shapes.
        MockURLProtocol.requestHandler = Self.respond(422, [
            "error": ["code": "seat_limit_exceeded", "message": "All seats in use"]
        ])
        do {
            _ = try await sdk.validate(licenseKey: Self.licenseKey)
            XCTFail("a seat-limit refusal must not fall back")
        } catch {}
        assertInvalid()
        assertGrantKept()

        sdk.shutdown()
        storagePrefix = "authoritative_denial_test_\(UUID().uuidString)_"
        sdk = makeSDK()
        try cacheActivationWithValidGrant()
        MockURLProtocol.requestHandler = Self.respond(200, Self.validation(valid: false, code: "seat_limit_exceeded"))
        _ = try await sdk.validate(licenseKey: Self.licenseKey)
        assertGrantKept()
        await assertNotOfflineValid("valid:false seat_limit_exceeded")
    }

    func testAFailedDenialWriteStillRefuses() async throws {
        // F8: neither the denial record nor the validation can be persisted.
        sdk.cache.simulatedWriteFailures = [LicenseCache.Key.authoritativeDenial, LicenseCache.Key.license]
        MockURLProtocol.requestHandler = Self.respond(200, Self.validation(valid: false, code: "not_entitled"))
        do {
            _ = try await sdk.validate(licenseKey: Self.licenseKey)
            XCTFail("a failed write must surface")
        } catch {}

        assertInvalid()
        XCTAssertFalse(sdk.checkEntitlement("updates").active)
        await assertNotOfflineValid("unpersisted denial")
    }

    // MARK: - Error-shaped denials

    func testVersionNotEntitledErrorUnderAlwaysDoesNotFallBackAndKeepsTheGrant() async throws {
        MockURLProtocol.requestHandler = Self.respond(403, [
            "error": ["code": "version_not_entitled", "message": "Not covered"]
        ])

        do {
            _ = try await sdk.validate(licenseKey: Self.licenseKey)
            XCTFail("an authoritative denial must not be answered by the offline grant")
        } catch let error as APIError {
            XCTAssertEqual(error.code, "version_not_entitled")
            XCTAssertTrue(error.isAuthoritativeDenial)
        }

        assertInvalid()
        assertGrantKept()
        XCTAssertFalse(sdk.checkEntitlement("updates").active)
        XCTAssertEqual(sdk.currentTrustedLicenseSource, .failClosedDenial)
    }

    func testEachThrownEntitlementDenialUnderAlwaysKeepsTheGrantAndDoesNotFallBack() async throws {
        // `not_entitled` is the one the engine throws (403) from validate
        // today; the other two arrive thrown from activate and from other
        // deployments. Each must behave the same.
        for (status, code) in [(403, "not_entitled"), (403, "version_not_entitled"), (422, "product_mismatch")] {
            sdk.shutdown()
            storagePrefix = "authoritative_denial_test_\(UUID().uuidString)_"
            sdk = makeSDK()
            try cacheActivationWithValidGrant()
            MockURLProtocol.requestHandler = Self.respond(status, [
                "error": ["code": code, "message": "Refused"]
            ])

            do {
                _ = try await sdk.validate(licenseKey: Self.licenseKey)
                XCTFail("\(code): the offline grant must not answer an authoritative denial")
            } catch let error as APIError {
                XCTAssertEqual(error.code, code)
            }
            assertInvalid()
            assertGrantKept()
            XCTAssertEqual(sdk.stateSnapshot().validation?.code, code)

            // A later outage must not revive it either.
            MockURLProtocol.requestHandler = { _ in throw URLError(.notConnectedToInternet) }
            do {
                _ = try await sdk.validate(licenseKey: Self.licenseKey)
                XCTFail("\(code): a persisted denial must block offline fallback")
            } catch {}
            assertInvalid()
        }
    }

    func testDenialCodesBlockFallbackUnderNetworkOnlyToo() async throws {
        sdk.shutdown()
        sdk = makeSDK(mode: .networkOnly)
        MockURLProtocol.requestHandler = Self.respond(501, [
            "error": ["code": "floating_not_implemented", "message": "Not implemented"]
        ])

        do {
            _ = try await sdk.validate(licenseKey: Self.licenseKey)
            XCTFail("expected the denial to be thrown")
        } catch let error as APIError {
            XCTAssertEqual(error.code, "floating_not_implemented")
        }
        assertInvalid()
        assertGrantKept()
    }

    // MARK: - valid:false denials (what the engine's validate returns)

    func testValidFalseDenialKeepsTheGrantAndLaterOutagesCannotOverruleIt() async throws {
        MockURLProtocol.requestHandler = Self.respond(200, Self.validation(valid: false, code: "version_not_entitled"))

        let result = try await sdk.validate(licenseKey: Self.licenseKey)
        XCTAssertFalse(result.valid)
        assertInvalid()
        assertGrantKept()

        // The network goes away; `.always` would previously have revived the
        // denied version from the offline grant.
        MockURLProtocol.requestHandler = { _ in throw URLError(.notConnectedToInternet) }
        do {
            _ = try await sdk.validate(licenseKey: Self.licenseKey)
            XCTFail("the persisted denial must block offline fallback")
        } catch {}
        assertInvalid()
        let explicit = await sdk.verifyCachedOffline()
        XCTAssertFalse(explicit.valid)
        XCTAssertEqual(explicit.code, "version_not_entitled")

        // Relaunch offline: launch verification must not overrule it either.
        sdk.shutdown()
        sdk = makeSDK()
        await sdk.waitForInitialization()
        assertInvalid()
        assertGrantKept()
    }

    func testRollingBackToACoveredVersionKeepsWorkingOffline() async throws {
        MockURLProtocol.requestHandler = Self.respond(200, Self.validation(valid: false, code: "version_not_entitled"))
        _ = try await sdk.validate(licenseKey: Self.licenseKey)
        assertInvalid()

        // The user reinstalls 2.9.0 (below the 3.0.0 ceiling) and is offline.
        MockURLProtocol.requestHandler = { _ in throw URLError(.notConnectedToInternet) }
        sdk.shutdown()
        sdk = makeSDK(appVersion: "2.9.0")
        await sdk.waitForInitialization()
        guard case .offlineValid = sdk.getStatus() else {
            return XCTFail("a covered version must keep working offline, got \(sdk.getStatus())")
        }

        let result = try await sdk.validate(licenseKey: Self.licenseKey)
        XCTAssertTrue(result.valid, "network fallback for the covered version")
    }

    // MARK: - Still eligible for `.always` fallback

    func testRateLimitUnderAlwaysFallsBackToTheValidGrant() async throws {
        MockURLProtocol.requestHandler = Self.respond(429, [
            "error": ["code": "rate_limited", "message": "Slow down"]
        ])

        let result = try await sdk.validate(licenseKey: Self.licenseKey)

        XCTAssertTrue(result.valid, result.code ?? "")
        guard case .offlineValid = sdk.getStatus() else {
            return XCTFail("expected offlineValid, got \(sdk.getStatus())")
        }
    }

    func testAuthErrorUnderAlwaysFallsBackToTheValidGrant() async throws {
        MockURLProtocol.requestHandler = Self.respond(403, [
            "error": ["code": "forbidden", "message": "Missing scope"]
        ])

        let result = try await sdk.validate(licenseKey: Self.licenseKey)

        XCTAssertTrue(result.valid, result.code ?? "")
    }

    // MARK: - Revocation is unchanged

    func testRevokedErrorStillPurges() async throws {
        MockURLProtocol.requestHandler = Self.respond(422, [
            "error": ["code": "revoked", "message": "Revoked"]
        ])

        do {
            _ = try await sdk.validate(licenseKey: Self.licenseKey)
            XCTFail("expected revocation to be thrown")
        } catch {}

        XCTAssertNil(sdk.currentLicense())
        XCTAssertNil(sdk.cache.getOfflineToken())
    }

    func testRevokedValidFalseStillPurgesTheGrant() async throws {
        MockURLProtocol.requestHandler = Self.respond(200, Self.validation(valid: false, code: "revoked"))

        let result = try await sdk.validate(licenseKey: Self.licenseKey)

        XCTAssertFalse(result.valid)
        XCTAssertNil(sdk.cache.getOfflineToken())
    }

    func testClassification() async {
        XCTAssertTrue(APIError(code: "VERSION_NOT_ENTITLED", message: "", status: 403).isAuthoritativeDenial)
        XCTAssertTrue(APIError(code: "product_mismatch", message: "", status: 422).isAuthoritativeDenial)
        XCTAssertFalse(APIError(code: "forbidden", message: "", status: 403).isAuthoritativeDenial)
        XCTAssertFalse(APIError(code: "rate_limited", message: "", status: 429).isAuthoritativeDenial)
        XCTAssertFalse(APIError(code: "revoked", message: "", status: 422).isAuthoritativeDenial)
        XCTAssertFalse(APIError(code: "version_not_entitled", message: "", status: 403).invalidatesCachedLicense)
    }
}
