//
//  StateAccessTests.swift
//  LicenseSeatSDKTests
//
//  #13: restoreLicense, stateSnapshot, the trusted-decision surface, and the
//  retained heartbeat/health results.
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
final class StateAccessTests: LicenseSeatTestCase {
    private static let productSlug = "state-app"
    private static let licenseKey = "STATE-KEY-0001"
    private static let deviceId = "state-device-0001"

    private var sdk: LicenseSeat!
    private var storagePrefix = ""

    nonisolated private static func makeMockedSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private func makeSDK() -> LicenseSeat {
        LicenseSeat(
            config: LicenseSeatConfig(
                apiBaseUrl: "https://api.test.com",
                apiKey: "pk_test_state",
                productSlug: Self.productSlug,
                storagePrefix: storagePrefix,
                deviceIdentifier: Self.deviceId,
                autoValidateInterval: 0,
                heartbeatInterval: 0,
                maxRetries: 0
            ),
            urlSession: Self.makeMockedSession()
        )
    }

    override func setUp() async throws {
        _ = URLProtocol.registerClass(MockURLProtocol.self)
        MockURLProtocol.reset()
        MockURLProtocol.requestHandler = { _ in throw URLError(.notConnectedToInternet) }
        storagePrefix = "state_access_test_\(UUID().uuidString)_"
        sdk = makeSDK()
        sdk.cache.clear()
    }

    override func tearDown() {
        MockURLProtocol.reset()
        URLProtocol.unregisterClass(MockURLProtocol.self)
        super.tearDown()
    }

    // MARK: - Fixtures

    private static func licenseJSON(
        entitlements: [[String: Any]] = [],
        status: String = "active"
    ) -> [String: Any] {
        [
            "object": "license",
            "key": licenseKey,
            "status": status,
            "starts_at": NSNull(),
            "expires_at": NSNull(),
            "mode": "hardware_locked",
            "plan_key": "pro",
            "seat_limit": 3,
            "active_seats": 1,
            "active_entitlements": entitlements,
            "metadata": NSNull(),
            "product": ["slug": productSlug, "name": "State App"]
        ]
    }

    private static func validationJSON(
        valid: Bool = true,
        entitlements: [[String: Any]] = []
    ) -> [String: Any] {
        [
            "object": "validation_result",
            "valid": valid,
            "code": valid ? NSNull() : "license_suspended" as Any,
            "message": NSNull(),
            "warnings": NSNull(),
            "license": licenseJSON(entitlements: entitlements),
            "activation": NSNull()
        ]
    }

    private static func json(
        _ request: URLRequest,
        _ status: Int,
        _ body: Any
    ) throws -> (HTTPURLResponse, Data) {
        (
            HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil,
                            headerFields: ["Content-Type": "application/json"])!,
            try JSONSerialization.data(withJSONObject: body)
        )
    }

    private func cachePersistedLicense(validated: Bool) throws {
        let validation = validated
            ? try JSONDecoder.licenseSeat.decode(
                ValidationResponse.self,
                from: JSONSerialization.data(withJSONObject: Self.validationJSON())
            )
            : nil
        XCTAssertTrue(sdk.cache.setLicense(License(
            licenseKey: Self.licenseKey,
            deviceId: Self.deviceId,
            activationId: "act-state-0001",
            activatedAt: Date(),
            lastValidated: Date(),
            validation: validation
        )))
    }

    /// Simulate a relaunch: a fresh instance over the same protected storage.
    private func relaunch() async {
        sdk.shutdown()
        sdk = makeSDK()
        await sdk.waitForInitialization()
    }

    // MARK: - Trust

    func testPersistedStateIsReportedButNotTrustedAfterLaunch() async throws {
        try cachePersistedLicense(validated: true)
        await relaunch()

        guard case .active = sdk.getStatus() else {
            return XCTFail("persisted status should still be reported: \(sdk.getStatus())")
        }
        XCTAssertFalse(sdk.isLicenseStateTrusted)
        XCTAssertNil(sdk.currentTrustedLicenseSource)
        XCTAssertNil(sdk.currentTrustedLicense)

        let snapshot = sdk.stateSnapshot()
        XCTAssertNil(snapshot.trustedSource)
        XCTAssertEqual(snapshot.license?.licenseKey, Self.licenseKey)
        XCTAssertEqual(snapshot.status, sdk.getStatus())
    }

    func testOnlineValidationEstablishesTrustAndFiltersExpiredEntitlements() async throws {
        try cachePersistedLicense(validated: false)
        let formatter = ISO8601DateFormatter()
        let body = Self.validationJSON(entitlements: [
            ["key": "pro", "expires_at": NSNull(), "metadata": NSNull()],
            ["key": "trial", "expires_at": formatter.string(from: Date().addingTimeInterval(-60)),
             "metadata": NSNull()]
        ])
        MockURLProtocol.requestHandler = { try Self.json($0, 200, body) }

        _ = try await sdk.validate(licenseKey: Self.licenseKey)

        XCTAssertTrue(sdk.isLicenseStateTrusted)
        XCTAssertEqual(sdk.currentTrustedLicenseSource, .onlineResponse)
        XCTAssertEqual(sdk.currentTrustedLicense?.activeEntitlements.map(\.key), ["pro"])
        let snapshot = sdk.stateSnapshot()
        XCTAssertEqual(snapshot.trustedSource, .onlineResponse)
        XCTAssertEqual(snapshot.activeEntitlements.map(\.key), ["pro"])
        XCTAssertTrue(snapshot.isOnline)
        XCTAssertNotNil(snapshot.lastSeenTimestamp)
    }

    func testOnlineDenialIsTrustedAsAFailClosedDenial() async throws {
        try cachePersistedLicense(validated: true)
        let body = Self.validationJSON(valid: false)
        MockURLProtocol.requestHandler = { try Self.json($0, 200, body) }

        _ = try await sdk.validate(licenseKey: Self.licenseKey)

        XCTAssertEqual(sdk.currentTrustedLicenseSource, .failClosedDenial)
        XCTAssertNil(sdk.currentTrustedLicense)
        XCTAssertEqual(sdk.stateSnapshot().activeEntitlements, [])
    }

    func testVerifiedOfflineArtifactIsTrustedAsSigned() async throws {
        try cachePersistedLicense(validated: false)
        let key = Curve25519.Signing.PrivateKey()
        let now = Int(Date().timeIntervalSince1970)
        let payload = OfflineTokenResponse.TokenPayload(
            schemaVersion: 1, licenseKey: Self.licenseKey, productSlug: Self.productSlug,
            planKey: "pro", mode: "hardware_locked", seatLimit: 3, deviceId: Self.deviceId,
            iat: now - 60, exp: now + 86_400, nbf: now - 60, licenseExpiresAt: nil,
            kid: "state-kid", entitlements: [], metadata: nil
        )
        let canonical = try CanonicalJSON.stringify(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(payload))
        )
        let token = OfflineTokenResponse(
            object: "offline_token",
            token: payload,
            signature: .init(
                algorithm: "Ed25519",
                keyId: "state-kid",
                value: Base64URL.encode(try key.signature(for: Data(canonical.utf8)))
            ),
            canonical: canonical
        )
        XCTAssertTrue(sdk.cache.setOfflineToken(token))
        XCTAssertTrue(sdk.cache.setPublicKey("state-kid", Base64URL.encode(key.publicKey.rawRepresentation)))

        await relaunch() // launch-time quick verification

        XCTAssertEqual(sdk.currentTrustedLicenseSource, .signedOfflineArtifact)
        XCTAssertEqual(sdk.currentTrustedLicense?.key, Self.licenseKey)
    }

    func testResetAndRevocationDropTrust() async throws {
        try cachePersistedLicense(validated: false)
        let body = Self.validationJSON()
        MockURLProtocol.requestHandler = { try Self.json($0, 200, body) }
        _ = try await sdk.validate(licenseKey: Self.licenseKey)
        XCTAssertTrue(sdk.isLicenseStateTrusted)

        sdk.reset()
        XCTAssertFalse(sdk.isLicenseStateTrusted)
        XCTAssertNil(sdk.stateSnapshot().trustedSource)
    }

    // MARK: - restoreLicense

    func testRestoreWithoutACachedLicense() async {
        let result = await sdk.restoreLicense()

        XCTAssertFalse(result.restored)
        XCTAssertNil(result.license)
        XCTAssertNil(result.error)
        guard case .inactive = result.status else {
            return XCTFail("unexpected status \(result.status)")
        }
    }

    func testRestoreValidatesOnlineOnceThenUsesTheEstablishedDecision() async throws {
        try cachePersistedLicense(validated: true)
        await relaunch()
        let body = Self.validationJSON()
        var requests = 0
        MockURLProtocol.requestHandler = { request in
            requests += 1
            return try Self.json(request, 200, body)
        }

        let first = await sdk.restoreLicense()
        XCTAssertTrue(first.restored)
        XCTAssertNil(first.error)
        XCTAssertEqual(first.validation?.valid, true)
        XCTAssertEqual(requests, 1)
        XCTAssertEqual(sdk.currentTrustedLicenseSource, .onlineResponse)

        let second = await sdk.restoreLicense()
        XCTAssertTrue(second.restored)
        XCTAssertEqual(requests, 1, "an established decision needs no network request")
    }

    func testRestoreOfflineWithoutAnArtifactReportsTheErrorAndKeepsTheCache() async throws {
        try cachePersistedLicense(validated: true)
        await relaunch()

        let result = await sdk.restoreLicense()

        XCTAssertNotNil(result.error)
        XCTAssertEqual(result.license?.licenseKey, Self.licenseKey)
        XCTAssertFalse(sdk.isLicenseStateTrusted)
    }

    func testRestoreAppliesAnAuthoritativeRefusal() async throws {
        try cachePersistedLicense(validated: true)
        await relaunch()
        MockURLProtocol.requestHandler = {
            try Self.json($0, 404, ["error": ["code": "license_not_found", "message": "Not found"]])
        }

        let result = await sdk.restoreLicense()

        XCTAssertFalse(result.restored)
        XCTAssertNil(result.license)
        XCTAssertEqual((result.error as? APIError)?.code, "license_not_found")
    }

    // MARK: - Retained heartbeat and health results

    func testHeartbeatResultsAreRetained() async throws {
        try cachePersistedLicense(validated: true)
        let receivedAt = "2026-11-05T12:00:00Z"
        let license = Self.licenseJSON()
        MockURLProtocol.requestHandler = { request in
            try Self.json(request, 200, [
                "object": "heartbeat",
                "received_at": receivedAt,
                "license": license
            ])
        }

        try await sdk.heartbeat()
        XCTAssertEqual(sdk.lastHeartbeatResponse?.object, "heartbeat")
        XCTAssertEqual(sdk.lastHeartbeatResponse?.license?.key, Self.licenseKey)
        XCTAssertNil(sdk.lastHeartbeatError)

        MockURLProtocol.requestHandler = {
            try Self.json($0, 503, ["error": ["code": "unavailable", "message": "Down"]])
        }
        do {
            try await sdk.heartbeat()
            XCTFail("expected the heartbeat to fail")
        } catch {}
        XCTAssertEqual((sdk.lastHeartbeatError as? APIError)?.status, 503)
        XCTAssertNotNil(sdk.lastHeartbeatResponse, "the last success is kept")

        sdk.reset()
        XCTAssertNil(sdk.lastHeartbeatResponse)
        XCTAssertNil(sdk.lastHeartbeatError)
    }

    func testHealthResultsAreRetained() async throws {
        MockURLProtocol.requestHandler = { request in
            try Self.json(request, 200, [
                "object": "health",
                "status": "healthy",
                "api_version": "2026-08-19",
                "timestamp": "2026-11-05T12:00:00Z"
            ])
        }
        _ = try await sdk.healthCheck()
        XCTAssertEqual(sdk.lastHealthResponse?.apiVersion, "2026-08-19")
        XCTAssertNil(sdk.lastHealthError)

        MockURLProtocol.requestHandler = { _ in throw URLError(.notConnectedToInternet) }
        do {
            _ = try await sdk.healthCheck()
            XCTFail("expected the health check to fail")
        } catch {}
        XCTAssertNotNil(sdk.lastHealthError)
        XCTAssertEqual(sdk.lastHealthResponse?.apiVersion, "2026-08-19")
    }
}

private extension JSONDecoder {
    static var licenseSeat: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
