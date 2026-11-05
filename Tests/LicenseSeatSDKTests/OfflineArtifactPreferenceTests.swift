//
//  OfflineArtifactPreferenceTests.swift
//  LicenseSeatSDKTests
//
//  #14: machine files are the preferred offline artifact for both refresh and
//  verification; the legacy offline token stays a fallback for servers, keys,
//  and caches that predate machine files.
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
final class OfflineArtifactPreferenceTests: LicenseSeatTestCase {

    // MARK: - Server-generated machine-file fixture (see Fixtures/README.md)

    private struct Fixture: Decodable {
        struct Case: Decodable {
            let response: AnyCodable
        }

        let publicKey: String
        let keyId: String
        let licenseKey: String
        let fingerprint: String
        let productSlug: String
        let activationId: String
        let cases: [String: Case]

        enum CodingKeys: String, CodingKey {
            case publicKey = "public_key"
            case keyId = "key_id"
            case licenseKey = "license_key"
            case fingerprint
            case productSlug = "product_slug"
            case activationId = "activation_id"
            case cases
        }
    }

    nonisolated private static let fixture: Fixture = {
        guard let url = Bundle.module.url(
            forResource: "machine_file_fixtures",
            withExtension: "json"
        ), let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(Fixture.self, from: data) else {
            fatalError("machine_file_fixtures.json is missing or unreadable")
        }
        return decoded
    }()

    private static let tokenKeyId = "legacy-token-key"

    private var sdk: LicenseSeat!
    private var storagePrefix = ""
    private let tokenSigningKey = Curve25519.Signing.PrivateKey()

    nonisolated private static func makeMockedSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private func makeConfig(legacyOfflineTokensEnabled: Bool = true) -> LicenseSeatConfig {
        var config = LicenseSeatConfig(
            apiBaseUrl: "https://api.test.com",
            apiKey: "pk_test_offline_artifacts",
            productSlug: Self.fixture.productSlug,
            storagePrefix: storagePrefix,
            deviceIdentifier: Self.fixture.fingerprint,
            autoValidateInterval: 0,
            heartbeatInterval: 0,
            maxRetries: 0,
            maxOfflineDays: 36_600
        )
        config.legacyOfflineTokensEnabled = legacyOfflineTokensEnabled
        return config
    }

    override func setUp() async throws {
        _ = URLProtocol.registerClass(MockURLProtocol.self)
        MockURLProtocol.reset()
        MockURLProtocol.requestHandler = { _ in
            throw URLError(.notConnectedToInternet)
        }
        storagePrefix = "offline_artifact_test_\(UUID().uuidString)_"
        sdk = LicenseSeat(config: makeConfig(), urlSession: Self.makeMockedSession())
        sdk.cache.clear()
        cacheFixtureIdentity()
    }

    override func tearDown() {
        MockURLProtocol.reset()
        URLProtocol.unregisterClass(MockURLProtocol.self)
        super.tearDown()
    }

    // MARK: - Helpers

    private func reconfigure(legacyOfflineTokensEnabled: Bool) {
        sdk.shutdown()
        sdk = LicenseSeat(
            config: makeConfig(legacyOfflineTokensEnabled: legacyOfflineTokensEnabled),
            urlSession: Self.makeMockedSession()
        )
    }

    private func cacheFixtureIdentity(licenseKey: String = fixture.licenseKey) {
        XCTAssertTrue(sdk.cache.setPublicKey(Self.fixture.keyId, Self.fixture.publicKey))
        XCTAssertTrue(sdk.cache.setLicense(License(
            licenseKey: licenseKey,
            deviceId: Self.fixture.fingerprint,
            activationId: Self.fixture.activationId,
            activatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            lastValidated: Date(timeIntervalSince1970: 1_700_000_000)
        )))
    }

    private static func responseData(_ name: String) throws -> Data {
        let fixtureCase = try XCTUnwrap(fixture.cases[name], "missing fixture case \(name)")
        return try JSONSerialization.data(withJSONObject: fixtureCase.response.value)
    }

    private static func machineFile(_ name: String) throws -> MachineFile {
        try JSONDecoder().decode(MachineFileResponse.self, from: responseData(name)).machineFile
    }

    private func signedToken(expiresIn seconds: Int = 30 * 86_400) throws -> OfflineTokenResponse {
        let now = Int(Date().timeIntervalSince1970)
        let payload = OfflineTokenResponse.TokenPayload(
            schemaVersion: 1,
            licenseKey: Self.fixture.licenseKey,
            productSlug: Self.fixture.productSlug,
            planKey: "legacy-plan",
            mode: "hardware_locked",
            seatLimit: 5,
            deviceId: Self.fixture.fingerprint,
            iat: now - 60,
            exp: now + seconds,
            nbf: now - 60,
            licenseExpiresAt: nil,
            kid: Self.tokenKeyId,
            entitlements: [],
            metadata: nil
        )
        let encoded = try JSONEncoder().encode(payload)
        let canonical = try CanonicalJSON.stringify(
            try JSONSerialization.jsonObject(with: encoded)
        )
        let signature = try tokenSigningKey.signature(for: Data(canonical.utf8))
        return OfflineTokenResponse(
            object: "offline_token",
            token: payload,
            signature: .init(
                algorithm: "Ed25519",
                keyId: Self.tokenKeyId,
                value: Base64URL.encode(signature)
            ),
            canonical: canonical
        )
    }

    private var tokenPublicKey: String {
        Base64URL.encode(tokenSigningKey.publicKey.rawRepresentation)
    }

    private static func response(
        _ request: URLRequest,
        status: Int,
        json: Any
    ) throws -> (HTTPURLResponse, Data) {
        (
            HTTPURLResponse(
                url: request.url!,
                statusCode: status,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!,
            try JSONSerialization.data(withJSONObject: json)
        )
    }

    /// A server whose machine-file endpoint answers with `machineFile`, and
    /// whose legacy offline-token endpoint serves a valid signed token.
    /// Returns a recorder of every request path, in order.
    private func installServer(
        machineFile: @escaping (URLRequest) throws -> (HTTPURLResponse, Data)
    ) throws -> PathRecorder {
        let recorder = PathRecorder()
        let tokenJSON = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(signedToken())
        )
        let tokenKey = tokenPublicKey
        MockURLProtocol.requestHandler = { request in
            let path = request.url?.path ?? ""
            recorder.append(path)
            if path.hasSuffix("/machine-file") {
                return try machineFile(request)
            }
            if path.hasSuffix("/offline-token") {
                return try Self.response(request, status: 200, json: tokenJSON)
            }
            if path.hasSuffix("/signing_keys/\(Self.tokenKeyId)") {
                return try Self.response(request, status: 200, json: [
                    "object": "signing_key",
                    "key_id": Self.tokenKeyId,
                    "algorithm": "Ed25519",
                    "public_key": tokenKey,
                    "status": "active"
                ])
            }
            throw URLError(.unsupportedURL)
        }
        return recorder
    }

    private func observe(_ events: [String]) -> EventRecorder {
        let recorder = EventRecorder()
        for event in events {
            recorder.subscriptions.append(sdk.on(event) { payload in
                recorder.events.append((event, payload))
            })
        }
        return recorder
    }

    /// Event delivery hops through the bus queue and then the main queue.
    /// Wait (bounded) until `count` events have landed, then a little longer
    /// so an event that should *not* have been emitted would be visible too.
    private func waitForEvents(_ recorder: EventRecorder, count: Int) async {
        let deadline = Date().addingTimeInterval(10)
        while recorder.events.count < count, Date() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        try? await Task.sleep(nanoseconds: 100_000_000)
    }

    // MARK: - Refresh preference

    func testSyncPrefersTheMachineFileAndNeverAsksForALegacyToken() async throws {
        // A token cached by 0.5.x is superseded (and discarded) by the newer
        // signed machine file, so it can never override its verdict later.
        XCTAssertTrue(sdk.cache.setOfflineToken(try signedToken()))
        let machineFileData = try Self.responseData("valid")
        let paths = try installServer { request in
            (
                HTTPURLResponse(url: request.url!, statusCode: 201, httpVersion: nil,
                                headerFields: ["Content-Type": "application/json"])!,
                machineFileData
            )
        }
        let events = observe(["offlineAssets:ready", "offlineToken:ready", "machineFile:ready"])

        await sdk.syncOfflineAssets()
        await waitForEvents(events, count: 2)

        XCTAssertEqual(sdk.currentMachineFile, try Self.machineFile("valid"))
        XCTAssertNil(sdk.cache.getOfflineToken())
        XCTAssertFalse(paths.paths.contains { $0.hasSuffix("/offline-token") }, "\(paths.paths)")
        XCTAssertEqual(events.names, ["machineFile:ready", "offlineAssets:ready"])
        XCTAssertEqual(
            (events.events.last?.1 as? [String: Any])?["artifact"] as? String,
            "machine_file"
        )
    }

    func testSyncFallsBackToTheLegacyTokenWhenTheKeyLacksTheMachineFileScope() async throws {
        let paths = try installServer { request in
            try Self.response(request, status: 403, json: [
                "error": ["code": "forbidden", "message": "Missing scope licenses:machine_file"]
            ])
        }
        let events = observe(["offlineAssets:ready", "offlineToken:ready", "machineFile:fetchError"])

        await sdk.syncOfflineAssets()
        await waitForEvents(events, count: 3)

        XCTAssertNil(sdk.currentMachineFile)
        XCTAssertEqual(sdk.cache.getOfflineToken()?.token.kid, Self.tokenKeyId)
        XCTAssertNotNil(sdk.currentLicense(), "a scope error must never revoke the license")
        XCTAssertEqual(
            paths.paths.filter { $0.hasSuffix("/machine-file") || $0.hasSuffix("/offline-token") }
                .map { ($0 as NSString).lastPathComponent },
            ["machine-file", "offline-token"]
        )
        XCTAssertEqual(
            events.names,
            ["machineFile:fetchError", "offlineToken:ready", "offlineAssets:ready"]
        )
        XCTAssertEqual(
            (events.events.last?.1 as? [String: Any])?["artifact"] as? String,
            "offline_token"
        )
    }

    func testSyncFallsBackToTheLegacyTokenOnAServerWithoutTheEndpoint() async throws {
        // A server that predates machine files: a plain, code-less 404.
        _ = try installServer { request in
            (
                HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil,
                                headerFields: ["Content-Type": "text/html"])!,
                Data("<html>Not Found</html>".utf8)
            )
        }

        await sdk.syncOfflineAssets()

        XCTAssertNil(sdk.currentMachineFile)
        XCTAssertEqual(sdk.cache.getOfflineToken()?.token.kid, Self.tokenKeyId)
        XCTAssertNotNil(sdk.currentLicense())
    }

    func testSyncFallsBackToTheLegacyTokenOnATransientServerFailure() async throws {
        _ = try installServer { request in
            try Self.response(request, status: 503, json: [
                "error": ["code": "unavailable", "message": "Down"]
            ])
        }

        await sdk.syncOfflineAssets()

        XCTAssertNil(sdk.currentMachineFile)
        XCTAssertEqual(sdk.cache.getOfflineToken()?.token.kid, Self.tokenKeyId)
    }

    func testAGenericMachineFileRefusalIsNotTreatedAsARevocation() async throws {
        // license_seat#34: the endpoint reports every validator refusal and
        // unexpected server errors as a generic 422.
        _ = try installServer { request in
            try Self.response(request, status: 422, json: [
                "error": ["code": "license_invalid_general",
                          "message": "Offline machine files are not supported for hardware_locked licenses."]
            ])
        }

        await sdk.syncOfflineAssets()

        XCTAssertNotNil(sdk.currentLicense())
        XCTAssertEqual(sdk.cache.getOfflineToken()?.token.kid, Self.tokenKeyId)
    }

    func testSyncDoesNotFallBackWhenLegacyTokensAreDisabled() async throws {
        reconfigure(legacyOfflineTokensEnabled: false)
        let paths = try installServer { request in
            try Self.response(request, status: 404, json: [
                "error": ["code": "not_found", "message": "Not found"]
            ])
        }
        let events = observe(["offlineAssets:fetchError", "offlineToken:ready"])

        await sdk.syncOfflineAssets()
        await waitForEvents(events, count: 1)

        XCTAssertNil(sdk.cache.getOfflineToken())
        XCTAssertFalse(paths.paths.contains { $0.hasSuffix("/offline-token") })
        XCTAssertEqual(events.names, ["offlineAssets:fetchError"])
        let payload = events.events.first?.1 as? [String: Any]
        XCTAssertEqual((payload?["machineFileError"] as? APIError)?.status, 404)
    }

    func testAuthoritativeMachineFileRefusalRevokesWithoutFallingBack() async throws {
        let paths = try installServer { request in
            try Self.response(request, status: 422, json: [
                "errors": [[
                    "code": "DEVICE_NOT_ACTIVATED",
                    "title": "Device not activated",
                    "detail": "Device must be activated before generating machine file."
                ]]
            ])
        }
        let events = observe(["license:revoked", "offlineToken:ready"])

        await sdk.syncOfflineAssets()
        await waitForEvents(events, count: 1)

        XCTAssertNil(sdk.currentLicense())
        XCTAssertNil(sdk.cache.getOfflineToken())
        XCTAssertFalse(paths.paths.contains { $0.hasSuffix("/offline-token") })
        XCTAssertEqual(events.names, ["license:revoked"])
    }

    // MARK: - Verification preference

    func testVerifyCachedOfflineUsesTheMachineFile() async throws {
        XCTAssertTrue(sdk.cache.setMachineFile(try Self.machineFile("valid")))

        let result = await sdk.verifyCachedOffline()

        XCTAssertTrue(result.valid, result.code ?? "")
        XCTAssertEqual(result.license.key, Self.fixture.licenseKey)
        XCTAssertEqual(result.license.planKey, "pro")
        XCTAssertEqual(
            Set(result.license.activeEntitlements.map(\.key)),
            ["pro", "beta-features"]
        )
    }

    func testMachineFileVerificationIsBoundToTheCachedActivationNotTheArtifact() async throws {
        // A restored artifact for another license must not verify against
        // its own unsigned metadata.
        sdk.cache.clear()
        cacheFixtureIdentity(licenseKey: "OTHER-LICENSE-KEY-0000")
        XCTAssertTrue(sdk.cache.setMachineFile(try Self.machineFile("valid")))

        let result = await sdk.verifyCachedOffline()

        XCTAssertFalse(result.valid)
        XCTAssertEqual(result.code, "license_mismatch")
    }

    func testADefinitiveMachineFileVerdictIsNotOverriddenByAnOlderToken() async throws {
        // E.g. the license end date was moved earlier: the newer machine file
        // says expired; an older token must not resurrect the grant.
        XCTAssertTrue(sdk.cache.setMachineFile(try Self.machineFile("expired")))
        XCTAssertTrue(sdk.cache.setOfflineToken(try signedToken()))
        XCTAssertTrue(sdk.cache.setPublicKey(Self.tokenKeyId, tokenPublicKey))

        let result = await sdk.verifyCachedOffline()

        XCTAssertFalse(result.valid)
        XCTAssertEqual(result.code, "token_expired")
    }

    func testAMachineFileThatCannotVouchFallsBackToTheLegacyToken() async throws {
        // Signed by a key this installation does not trust (and the key
        // endpoint is unreachable): no verdict either way, so the legacy
        // token is consulted.
        XCTAssertTrue(sdk.cache.setMachineFile(try Self.machineFile("wrong_key")))
        XCTAssertTrue(sdk.cache.setOfflineToken(try signedToken()))
        XCTAssertTrue(sdk.cache.setPublicKey(Self.tokenKeyId, tokenPublicKey))

        let result = await sdk.verifyCachedOffline()

        XCTAssertTrue(result.valid, result.code ?? "")
        XCTAssertEqual(result.license.planKey, "legacy-plan")
    }

    func testWithLegacyTokensDisabledTheMachineFileVerdictStands() async throws {
        reconfigure(legacyOfflineTokensEnabled: false)
        XCTAssertTrue(sdk.cache.setMachineFile(try Self.machineFile("expired")))
        XCTAssertTrue(sdk.cache.setOfflineToken(try signedToken()))
        XCTAssertTrue(sdk.cache.setPublicKey(Self.tokenKeyId, tokenPublicKey))

        let result = await sdk.verifyCachedOffline()

        XCTAssertFalse(result.valid)
        XCTAssertEqual(result.code, "token_expired")
    }

    func testNoArtifactKeepsTheLegacyCode() async throws {
        let result = await sdk.verifyCachedOffline()

        XCTAssertFalse(result.valid)
        XCTAssertEqual(result.code, "no_offline_token")
    }

    // MARK: - Launch-time quick verification

    func testLaunchVerifiesACachedMachineFileWithoutTheNetwork() async throws {
        XCTAssertTrue(sdk.cache.setMachineFile(try Self.machineFile("valid")))
        let paths = try installServer { request in
            try Self.response(request, status: 500, json: [:])
        }

        reconfigure(legacyOfflineTokensEnabled: true)
        await sdk.waitForInitialization()

        guard case .offlineValid(let details) = sdk.getStatus() else {
            return XCTFail("expected offlineValid, got \(sdk.getStatus())")
        }
        XCTAssertEqual(Set(details.entitlements.map(\.key)), ["pro", "beta-features"])
        XCTAssertTrue(sdk.checkEntitlement("pro").active)
        XCTAssertTrue(paths.paths.isEmpty, "launch verification hit the network: \(paths.paths)")
    }

    func testLaunchTreatsAMachineFileThatCannotVouchAsAbsent() async throws {
        XCTAssertTrue(sdk.cache.setMachineFile(try Self.machineFile("wrong_key")))

        reconfigure(legacyOfflineTokensEnabled: true)
        await sdk.waitForInitialization()

        guard case .pending = sdk.getStatus() else {
            return XCTFail("no offline denial before online validation, got \(sdk.getStatus())")
        }
    }

    func testLaunchStillVerifiesALegacyTokenCachedByAnOlderRelease() async throws {
        // Upgrade path from 0.5.x: only a legacy token is cached.
        XCTAssertTrue(sdk.cache.setOfflineToken(try signedToken()))
        XCTAssertTrue(sdk.cache.setPublicKey(Self.tokenKeyId, tokenPublicKey))

        reconfigure(legacyOfflineTokensEnabled: true)
        await sdk.waitForInitialization()

        guard case .offlineValid = sdk.getStatus() else {
            return XCTFail("expected offlineValid, got \(sdk.getStatus())")
        }
    }
}

/// Collects request paths from the URLProtocol thread.
private final class PathRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    func append(_ path: String) {
        lock.lock()
        storage.append(path)
        lock.unlock()
    }

    var paths: [String] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

@MainActor
private final class EventRecorder {
    var events: [(String, Any)] = []
    var subscriptions: [AnyObject] = []

    var names: [String] { events.map(\.0) }
}
