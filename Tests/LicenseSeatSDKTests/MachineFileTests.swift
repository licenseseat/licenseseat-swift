//
//  MachineFileTests.swift
//  LicenseSeatSDKTests
//
//  Golden-fixture and claim-boundary coverage for machine files.
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
final class MachineFileTests: LicenseSeatTestCase {

    // MARK: - Golden Fixture Model
    //
    // `machine_file_fixtures.json` is produced by
    // Tests/LicenseSeatSDKTests/Fixtures/generate_machine_file_fixtures.rb,
    // which drives the license_seat gem's own OfflineMachineFile crypto. These
    // certificates are byte-for-byte what the server issues.

    private struct Fixture: Decodable {
        struct Case: Decodable {
            let description: String
            let response: AnyCodable
            let expected: Expected

            struct Expected: Decodable {
                let valid: Bool
                let code: String?
            }
        }

        let publicKey: String
        let wrongPublicKey: String
        let keyId: String
        let licenseKey: String
        let fingerprint: String
        let productSlug: String
        let activationId: String
        let issuedAtUnix: Int
        let expiresAtUnix: Int
        let gracePeriodSeconds: Int
        let cases: [String: Case]

        enum CodingKeys: String, CodingKey {
            case publicKey = "public_key"
            case wrongPublicKey = "wrong_public_key"
            case keyId = "key_id"
            case licenseKey = "license_key"
            case fingerprint = "fingerprint"
            case productSlug = "product_slug"
            case activationId = "activation_id"
            case issuedAtUnix = "issued_at_unix"
            case expiresAtUnix = "expires_at_unix"
            case gracePeriodSeconds = "grace_period_seconds"
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

    private var sdk: LicenseSeat!

    nonisolated private static func makeMockedSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private static func makeConfig(
        productSlug: String? = fixture.productSlug,
        maxOfflineDays: Int = 36_600,
        deviceIdentifier: String? = fixture.fingerprint,
        offlineFallbackEnabled: Bool = true
    ) -> LicenseSeatConfig {
        LicenseSeatConfig(
            apiBaseUrl: "https://api.test.com",
            apiKey: "pk_test_machinefile",
            productSlug: productSlug,
            storagePrefix: "machine_file_test_\(UUID().uuidString)_",
            deviceIdentifier: deviceIdentifier,
            autoValidateInterval: 0,
            heartbeatInterval: 0,
            maxRetries: 0,
            offlineFallbackEnabled: offlineFallbackEnabled,
            maxOfflineDays: maxOfflineDays
        )
    }

    override func setUp() async throws {
        _ = URLProtocol.registerClass(MockURLProtocol.self)
        MockURLProtocol.reset()
        MockURLProtocol.requestHandler = { _ in
            throw URLError(.notConnectedToInternet)
        }
        sdk = LicenseSeat(config: Self.makeConfig(), urlSession: Self.makeMockedSession())
        sdk.cache.clear()
        cacheFixtureIdentity(on: sdk)
    }

    // Sync teardown limited to nonisolated statics (the APIClientTests
    // pattern) — assumeIsolated over isolated state trips Swift 6 strict
    // concurrency on the Linux lane. The UUID storage prefix isolates tests,
    // so skipping sdk.reset() leaks nothing across tests.
    override func tearDown() {
        MockURLProtocol.reset()
        URLProtocol.unregisterClass(MockURLProtocol.self)
        super.tearDown()
    }

    // MARK: - Helpers

    private func cacheFixtureIdentity(
        on seat: LicenseSeat,
        activationId: String = fixture.activationId,
        publicKey: String? = nil
    ) {
        XCTAssertTrue(
            seat.cache.setPublicKey(
                Self.fixture.keyId,
                publicKey ?? Self.fixture.publicKey
            )
        )
        XCTAssertTrue(
            seat.cache.setLicense(
                License(
                    licenseKey: Self.fixture.licenseKey,
                    deviceId: Self.fixture.fingerprint,
                    activationId: activationId,
                    activatedAt: Date(timeIntervalSince1970: 1_700_000_000),
                    lastValidated: Date(timeIntervalSince1970: 1_700_000_000)
                )
            )
        )
    }

    private static func responseData(_ name: String) throws -> Data {
        let fixtureCase = try XCTUnwrap(fixture.cases[name], "missing fixture case \(name)")
        return try JSONSerialization.data(
            withJSONObject: fixtureCase.response.value
        )
    }

    private static func machineFile(_ name: String) throws -> MachineFile {
        try JSONDecoder()
            .decode(MachineFileResponse.self, from: responseData(name))
            .machineFile
    }

    private static func expectedCode(_ name: String) throws -> String {
        try XCTUnwrap(XCTUnwrap(fixture.cases[name]).expected.code)
    }

    // MARK: - Golden Fixture: Valid

    func testServerFixtureVerifiesEndToEnd() throws {
        let machineFile = try Self.machineFile("valid")

        XCTAssertEqual(machineFile.algorithm, MachineFile.algorithmIdentifier)
        XCTAssertEqual(machineFile.licenseKey, Self.fixture.licenseKey)
        XCTAssertEqual(machineFile.fingerprint, Self.fixture.fingerprint)
        XCTAssertEqual(
            machineFile.issuedAt.map { Int($0.timeIntervalSince1970) },
            Self.fixture.issuedAtUnix
        )
        XCTAssertEqual(sdk.machineFileKeyId(machineFile), Self.fixture.keyId)

        let result = try sdk.verifyMachineFile(machineFile)

        XCTAssertTrue(result.valid, result.message ?? "")
        XCTAssertNil(result.code)
        let payload = try XCTUnwrap(result.payload)
        XCTAssertEqual(payload.schemaVersion, 2)
        XCTAssertEqual(payload.keyId, Self.fixture.keyId)
        XCTAssertEqual(payload.licenseKey, Self.fixture.licenseKey)
        XCTAssertEqual(payload.fingerprint, Self.fixture.fingerprint)
        XCTAssertEqual(payload.machineId, Self.fixture.activationId)
        XCTAssertEqual(payload.productSlug, Self.fixture.productSlug)
        XCTAssertEqual(payload.iat, Self.fixture.issuedAtUnix)
        XCTAssertEqual(payload.exp, Self.fixture.expiresAtUnix)
        XCTAssertEqual(payload.exp - payload.iat, payload.ttl)
        XCTAssertEqual(payload.gracePeriod, Self.fixture.gracePeriodSeconds)
        XCTAssertEqual(payload.sdkVersion, "swift-0.4.2")
        XCTAssertEqual(payload.platform, "macos")
        XCTAssertEqual(payload.deviceName, "Fixture Studio Mac")
        XCTAssertEqual(payload.fingerprintComponents["platform"], "macos")

        // The included license travels inside the encrypted payload and must
        // survive decoding intact, Unicode and all.
        let license = try XCTUnwrap(payload.license)
        XCTAssertEqual(license.key, Self.fixture.licenseKey)
        XCTAssertEqual(license.status, "active")
        XCTAssertEqual(license.mode, "hardware_locked")
        XCTAssertEqual(license.planKey, "pro")
        XCTAssertEqual(license.seatLimit, 5)
        XCTAssertEqual(license.product.slug, Self.fixture.productSlug)
        XCTAssertEqual(
            Set(license.activeEntitlements.map(\.key)),
            ["pro", "beta-features"]
        )
        XCTAssertEqual(license.metadata?["unicode"], AnyCodable("Olá 👋"))
        XCTAssertTrue(payload.hasEntitlement("pro"))
        XCTAssertFalse(payload.hasEntitlement("enterprise"))
    }

    func testServerFixtureEmitsVerifiedEvent() throws {
        var observed: [String] = []
        let subscription = sdk.on("machineFile:verified") { _ in
            observed.append("verified")
        }
        defer { subscription.cancel() }

        let result = try sdk.verifyMachineFile(try Self.machineFile("valid"))
        XCTAssertTrue(result.valid)

        let expectation = expectation(description: "verified event delivered")
        DispatchQueue.main.async { expectation.fulfill() }
        wait(for: [expectation], timeout: 2)
        XCTAssertEqual(observed, ["verified"])
    }

    // MARK: - Golden Fixture: Rejections

    func testExpiredServerFixtureIsRejectedAsExpired() throws {
        let result = try sdk.verifyMachineFile(try Self.machineFile("expired"))

        XCTAssertFalse(result.valid)
        XCTAssertNil(result.payload)
        XCTAssertEqual(result.code, "token_expired")
        XCTAssertEqual(result.code, try Self.expectedCode("expired"))
    }

    func testTamperedServerFixtureIsRejectedBeforeDecryption() throws {
        // One flipped ciphertext character. The signature covers `enc`, so this
        // must fail on the signature and never reach AES at all.
        let result = try sdk.verifyMachineFile(
            try Self.machineFile("tampered_signature")
        )

        XCTAssertFalse(result.valid)
        XCTAssertEqual(result.code, "signature_invalid")
        XCTAssertEqual(result.code, try Self.expectedCode("tampered_signature"))
    }

    func testResignedTamperedCiphertextFailsTheAuthenticationTag() throws {
        // Signature valid, ciphertext modified: proves the GCM tag is enforced
        // independently and is not implied by the outer signature.
        let result = try sdk.verifyMachineFile(
            try Self.machineFile("tampered_ciphertext_resigned")
        )

        XCTAssertFalse(result.valid)
        XCTAssertEqual(result.code, "decryption_failed")
        XCTAssertEqual(
            result.code,
            try Self.expectedCode("tampered_ciphertext_resigned")
        )
    }

    func testFixtureSignedByAnotherKeyIsRejected() throws {
        let result = try sdk.verifyMachineFile(try Self.machineFile("wrong_key"))

        XCTAssertFalse(result.valid)
        XCTAssertEqual(result.code, "signature_invalid")
        XCTAssertEqual(result.code, try Self.expectedCode("wrong_key"))
    }

    func testValidFixtureIsRejectedUnderTheWrongPublicKey() throws {
        let result = try sdk.verifyMachineFile(
            try Self.machineFile("valid"),
            publicKeyB64: Self.fixture.wrongPublicKey
        )

        XCTAssertFalse(result.valid)
        XCTAssertEqual(result.code, "signature_invalid")
    }

    // MARK: - Identity Binding

    func testFingerprintMismatchIsRejectedBeforeAnyCryptography() throws {
        let result = try sdk.verifyMachineFile(
            try Self.machineFile("valid"),
            fingerprint: "a-completely-different-device"
        )

        XCTAssertFalse(result.valid)
        XCTAssertEqual(result.code, "fingerprint_mismatch")
    }

    func testWrongFingerprintCannotDeriveTheDecryptionKey() throws {
        // Strip the plaintext relationship metadata so the early binding check
        // cannot short-circuit: the device binding must still hold because the
        // AES key is derived from the fingerprint itself.
        let certificate = try Self.machineFile("valid").certificate
        let result = try sdk.verifyMachineFile(
            MachineFile(certificate: certificate),
            fingerprint: "a-completely-different-device"
        )

        XCTAssertFalse(result.valid)
        XCTAssertEqual(result.code, "decryption_failed")
    }

    func testWrongLicenseKeyIsRejected() throws {
        let result = try sdk.verifyMachineFile(
            try Self.machineFile("valid"),
            licenseKey: "MF-FIXTURE-0000-0000-0000"
        )

        XCTAssertFalse(result.valid)
        XCTAssertEqual(result.code, "license_mismatch")
    }

    func testProductMismatchIsRejected() throws {
        let otherProduct = LicenseSeat(
            config: Self.makeConfig(productSlug: "some-other-app"),
            urlSession: Self.makeMockedSession()
        )
        defer { otherProduct.reset() }
        otherProduct.cache.clear()
        cacheFixtureIdentity(on: otherProduct)

        let result = try otherProduct.verifyMachineFile(try Self.machineFile("valid"))

        XCTAssertFalse(result.valid)
        XCTAssertEqual(result.code, "product_mismatch")
    }

    func testActivationMismatchIsRejected() throws {
        let reactivated = LicenseSeat(
            config: Self.makeConfig(),
            urlSession: Self.makeMockedSession()
        )
        defer { reactivated.reset() }
        reactivated.cache.clear()
        cacheFixtureIdentity(
            on: reactivated,
            activationId: "99999999-9999-9999-9999-999999999999"
        )

        let result = try reactivated.verifyMachineFile(try Self.machineFile("valid"))

        XCTAssertFalse(result.valid)
        XCTAssertEqual(result.code, "activation_mismatch")
    }

    func testMissingSigningKeyThrowsRatherThanReportingInvalid() throws {
        let bare = LicenseSeat(
            config: Self.makeConfig(),
            urlSession: Self.makeMockedSession()
        )
        defer { bare.reset() }
        bare.cache.clear()

        XCTAssertThrowsError(
            try bare.verifyMachineFile(try Self.machineFile("valid"))
        ) { error in
            XCTAssertEqual(error as? LicenseSeatError, .invalidPublicKey)
        }
    }

    func testOfflineAuthorityDisabledFailsClosed() throws {
        // Since 0.5.0, disabling offline authority is an explicit flag;
        // maxOfflineDays == 0 means "no additional host age cap".
        let disabled = LicenseSeat(
            config: Self.makeConfig(offlineFallbackEnabled: false),
            urlSession: Self.makeMockedSession()
        )
        defer { disabled.reset() }
        disabled.cache.clear()
        cacheFixtureIdentity(on: disabled)

        let result = try disabled.verifyMachineFile(try Self.machineFile("valid"))

        XCTAssertFalse(result.valid)
        XCTAssertEqual(result.code, "offline_disabled")
    }

    func testMaximumOfflineAgeCapsAnOtherwiseValidArtifact() throws {
        // Host policy is an independent ceiling: a three day old artifact whose
        // own signed window runs for another month must still be retired by a
        // one day `maxOfflineDays`.
        let now = Int(Date().timeIntervalSince1970)
        let artifact = try makeSyntheticMachineFile(
            iat: now - (3 * 86_400),
            exp: now + (30 * 86_400)
        )

        let permissive = try sdk.verifyMachineFile(
            artifact.machineFile,
            publicKeyB64: artifact.publicKeyB64
        )
        XCTAssertTrue(permissive.valid, permissive.message ?? "")

        let strict = LicenseSeat(
            config: Self.makeConfig(maxOfflineDays: 1),
            urlSession: Self.makeMockedSession()
        )
        defer { strict.reset() }
        strict.cache.clear()
        cacheFixtureIdentity(on: strict)

        let result = try strict.verifyMachineFile(
            artifact.machineFile,
            publicKeyB64: artifact.publicKeyB64
        )

        XCTAssertFalse(result.valid)
        XCTAssertEqual(result.code, "grace_period_expired")
    }

    // MARK: - Response Decoding

    func testResponseDecodingRejectsUnknownMembers() throws {
        var object = try XCTUnwrap(
            try JSONSerialization.jsonObject(
                with: Self.responseData("valid")
            ) as? [String: Any]
        )
        var data = try XCTUnwrap(object["data"] as? [String: Any])
        var attributes = try XCTUnwrap(data["attributes"] as? [String: Any])
        attributes["unexpected"] = "value"
        data["attributes"] = attributes
        object["data"] = data

        XCTAssertThrowsError(
            try JSONDecoder().decode(
                MachineFileResponse.self,
                from: try JSONSerialization.data(withJSONObject: object)
            )
        )
    }

    func testResponseDecodingRejectsAnUnsupportedAlgorithm() throws {
        var object = try XCTUnwrap(
            try JSONSerialization.jsonObject(
                with: Self.responseData("valid")
            ) as? [String: Any]
        )
        var data = try XCTUnwrap(object["data"] as? [String: Any])
        var attributes = try XCTUnwrap(data["attributes"] as? [String: Any])
        attributes["algorithm"] = "aes-128-cbc"
        data["attributes"] = attributes
        object["data"] = data

        XCTAssertThrowsError(
            try JSONDecoder().decode(
                MachineFileResponse.self,
                from: try JSONSerialization.data(withJSONObject: object)
            )
        )
    }

    func testResponseDecodingRejectsInconsistentLifetimeClaims() throws {
        var object = try XCTUnwrap(
            try JSONSerialization.jsonObject(
                with: Self.responseData("valid")
            ) as? [String: Any]
        )
        var data = try XCTUnwrap(object["data"] as? [String: Any])
        var attributes = try XCTUnwrap(data["attributes"] as? [String: Any])
        attributes["ttl"] = 60
        data["attributes"] = attributes
        object["data"] = data

        XCTAssertThrowsError(
            try JSONDecoder().decode(
                MachineFileResponse.self,
                from: try JSONSerialization.data(withJSONObject: object)
            )
        )
    }

    // MARK: - Checkout

    func testCheckoutVerifiesAndCachesTheArtifact() async throws {
        let responseData = try Self.responseData("valid")
        var observedPaths: [String] = []
        var requestBody: [String: Any] = [:]
        let publicKey = Self.fixture.publicKey
        let keyId = Self.fixture.keyId

        MockURLProtocol.requestHandler = { request in
            let path = request.url?.path ?? ""
            observedPaths.append(path)
            let ok = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            if path.hasSuffix("/machine-file") {
                requestBody = MockURLProtocol.jsonBody(for: request)
                return (ok, responseData)
            }
            if path.contains("/signing_keys/") {
                let body = try JSONSerialization.data(withJSONObject: [
                    "object": "signing_key",
                    "key_id": keyId,
                    "algorithm": "Ed25519",
                    "public_key": publicKey,
                    "status": "active"
                ])
                return (ok, body)
            }
            throw URLError(.unsupportedURL)
        }

        // Force the signing key to be fetched rather than reused.
        sdk.cache.clear()
        cacheFixtureIdentity(on: sdk)
        sdk.cache.deleteProtectedData(forKey: LicenseCache.Key.publicKeys)

        let machineFile = try await sdk.checkoutMachineFile(
            licenseKey: Self.fixture.licenseKey,
            fingerprint: Self.fixture.fingerprint,
            ttlDays: 30
        )

        XCTAssertEqual(machineFile.licenseKey, Self.fixture.licenseKey)
        XCTAssertEqual(sdk.currentMachineFile, machineFile)
        XCTAssertEqual(sdk.currentMachineFileKeyId, Self.fixture.keyId)
        XCTAssertTrue(
            observedPaths.contains { $0.hasSuffix("/products/hustl/licenses/machine-file") },
            "unexpected paths: \(observedPaths)"
        )
        XCTAssertTrue(observedPaths.contains { $0.contains("/signing_keys/") })

        // Body mirrors the Rust client: canonical field plus both legacy
        // aliases, the requested TTL in days, and the license include.
        XCTAssertEqual(requestBody["license_key"] as? String, Self.fixture.licenseKey)
        XCTAssertEqual(requestBody["fingerprint"] as? String, Self.fixture.fingerprint)
        XCTAssertEqual(requestBody["device_id"] as? String, Self.fixture.fingerprint)
        XCTAssertEqual(
            requestBody["device_fingerprint"] as? String,
            Self.fixture.fingerprint
        )
        XCTAssertEqual(requestBody["ttl"] as? Int, 30)
        XCTAssertEqual(requestBody["include"] as? [String], ["license"])
        XCTAssertNil(requestBody["grace_period"])
    }

    func testCheckoutRejectsAResponseForAnotherLicense() async throws {
        let responseData = try Self.responseData("valid")
        MockURLProtocol.requestHandler = { request in
            let ok = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (ok, responseData)
        }

        do {
            _ = try await sdk.checkoutMachineFile(
                licenseKey: "MF-FIXTURE-0000-0000-0000",
                fingerprint: Self.fixture.fingerprint
            )
            XCTFail("checkout accepted a mismatched response")
        } catch let error as APIError {
            XCTAssertEqual(error.code, "invalid_response")
        }
        XCTAssertNil(sdk.currentMachineFile)
    }

    func testCheckoutRejectsDisagreeingFingerprintAliases() async throws {
        var options = MachineFileCheckoutOptions(
            fingerprint: Self.fixture.fingerprint
        )
        options.deviceId = "another-device-fingerprint"

        do {
            _ = try await sdk.checkoutMachineFile(
                licenseKey: Self.fixture.licenseKey,
                options: options
            )
            XCTFail("checkout accepted disagreeing fingerprint aliases")
        } catch let error as APIError {
            XCTAssertEqual(error.code, "invalid_identity")
        }
    }

    func testCheckoutRejectsAnOutOfRangeGracePeriod() async throws {
        var options = MachineFileCheckoutOptions()
        options.gracePeriodDays = 31

        do {
            _ = try await sdk.checkoutMachineFile(
                licenseKey: Self.fixture.licenseKey,
                options: options
            )
            XCTFail("checkout accepted a grace period above the server maximum")
        } catch let error as APIError {
            XCTAssertEqual(error.code, "invalid_identity")
        }
    }

    // MARK: - Cache

    func testCachedMachineFileRoundTripsAndIsClearedOnReset() throws {
        let machineFile = try Self.machineFile("valid")

        XCTAssertTrue(sdk.cache.setMachineFile(machineFile))
        XCTAssertEqual(sdk.currentMachineFile, machineFile)

        sdk.cache.clear()
        XCTAssertNil(sdk.currentMachineFile)
    }

    // MARK: - Claim Boundaries
    //
    // Synthetic artifacts in the server's exact format, so lifetime boundaries
    // can be exercised at controlled instants. Every one of them is a genuine
    // AES-256-GCM + Ed25519 machine file; only the claims move.

    private struct SyntheticMachineFile {
        let machineFile: MachineFile
        let publicKeyB64: String
    }

    private func makeSyntheticMachineFile(
        keyId: String = "synthetic-key",
        innerKeyId: String? = nil,
        licenseKey: String = fixture.licenseKey,
        fingerprint: String = fixture.fingerprint,
        productSlug: String = fixture.productSlug,
        activationId: String = fixture.activationId,
        iat: Int,
        nbf: Int? = nil,
        exp: Int,
        ttl: Int? = nil,
        gracePeriod: Int = 0,
        signingKey: Curve25519.Signing.PrivateKey = Curve25519.Signing.PrivateKey()
    ) throws -> SyntheticMachineFile {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]

        let payload: [String: Any] = [
            "meta": [
                "schema_version": 2,
                "issued": formatter.string(from: Date(timeIntervalSince1970: Double(iat))),
                "iat": iat,
                "expiry": formatter.string(from: Date(timeIntervalSince1970: Double(exp))),
                "exp": exp,
                "nbf": nbf ?? iat,
                "ttl": ttl ?? (exp - iat),
                "grace_period": gracePeriod,
                "lic": licenseKey,
                "license_exp": NSNull(),
                "kid": innerKeyId ?? keyId,
                "sdk_version": NSNull()
            ],
            "data": [
                "type": "machines",
                "id": activationId,
                "attributes": [
                    "fingerprint": fingerprint,
                    "fingerprint_components": NSNull(),
                    "name": NSNull(),
                    "platform": NSNull(),
                    "created": formatter.string(from: Date(timeIntervalSince1970: Double(iat))),
                    "metadata": [String: Any]()
                ],
                "relationships": [
                    "license": ["data": ["type": "licenses", "id": licenseKey]],
                    "product": ["data": ["type": "products", "id": productSlug]]
                ]
            ],
            "included": [Any]()
        ]

        let plaintext = try JSONSerialization.data(
            withJSONObject: payload,
            options: [.sortedKeys]
        )
        var digest = SHA256()
        digest.update(data: Data(licenseKey.utf8))
        digest.update(data: Data(fingerprint.utf8))
        let sealed = try AES.GCM.seal(
            plaintext,
            using: SymmetricKey(data: Data(digest.finalize()))
        )
        let enc = [
            Base64URL.encode(sealed.ciphertext),
            Base64URL.encode(Data(sealed.nonce)),
            Base64URL.encode(sealed.tag)
        ].joined(separator: ".")
        let signature = try signingKey.signature(for: Data("machine/\(enc)".utf8))
        let envelope = try JSONSerialization.data(withJSONObject: [
            "enc": enc,
            "sig": Base64URL.encode(signature),
            "alg": MachineFile.algorithmIdentifier,
            "kid": keyId
        ])

        var lines = [MachineFileFormat.beginArmor]
        let encoded = envelope.base64EncodedString()
        var index = encoded.startIndex
        while index < encoded.endIndex {
            let end = encoded.index(index, offsetBy: 64, limitedBy: encoded.endIndex)
                ?? encoded.endIndex
            lines.append(String(encoded[index..<end]))
            index = end
        }
        lines.append(MachineFileFormat.endArmor)

        return SyntheticMachineFile(
            machineFile: MachineFile(certificate: lines.joined(separator: "\n")),
            publicKeyB64: Base64URL.encode(signingKey.publicKey.rawRepresentation)
        )
    }

    func testSignedGracePeriodExtendsAnExpiredArtifact() throws {
        let now = Int(Date().timeIntervalSince1970)
        let artifact = try makeSyntheticMachineFile(
            iat: now - (10 * 86_400),
            exp: now - 86_400,
            gracePeriod: 3 * 86_400
        )

        let result = try sdk.verifyMachineFile(
            artifact.machineFile,
            publicKeyB64: artifact.publicKeyB64
        )

        XCTAssertTrue(result.valid, result.message ?? "")
        XCTAssertEqual(result.payload?.gracePeriod, 3 * 86_400)
    }

    func testExpiryWithoutGraceIsNotExtended() throws {
        let now = Int(Date().timeIntervalSince1970)
        let artifact = try makeSyntheticMachineFile(
            iat: now - (10 * 86_400),
            exp: now - 86_400,
            gracePeriod: 0
        )

        let result = try sdk.verifyMachineFile(
            artifact.machineFile,
            publicKeyB64: artifact.publicKeyB64
        )

        XCTAssertFalse(result.valid)
        XCTAssertEqual(result.code, "token_expired")
    }

    func testGraceCannotOutlastItsSignedBound() throws {
        let now = Int(Date().timeIntervalSince1970)
        let artifact = try makeSyntheticMachineFile(
            iat: now - (10 * 86_400),
            exp: now - 86_400,
            // One second past the 30 day maximum the issuer will ever sign.
            gracePeriod: (30 * 86_400) + 1
        )

        let result = try sdk.verifyMachineFile(
            artifact.machineFile,
            publicKeyB64: artifact.publicKeyB64
        )

        XCTAssertFalse(result.valid)
        XCTAssertEqual(result.code, "invalid_machine_file_claims")
    }

    func testNotYetValidArtifactIsRejected() throws {
        let now = Int(Date().timeIntervalSince1970)
        let artifact = try makeSyntheticMachineFile(
            iat: now - 60,
            nbf: now + 3_600,
            exp: now + 7_200,
            ttl: 7_260
        )

        let result = try sdk.verifyMachineFile(
            artifact.machineFile,
            publicKeyB64: artifact.publicKeyB64
        )

        XCTAssertFalse(result.valid)
        XCTAssertEqual(result.code, "token_not_yet_valid")
    }

    func testFutureIssuanceIsTreatedAsClockTampering() throws {
        let now = Int(Date().timeIntervalSince1970)
        let artifact = try makeSyntheticMachineFile(
            iat: now + 7_200,
            exp: now + 14_400
        )

        let result = try sdk.verifyMachineFile(
            artifact.machineFile,
            publicKeyB64: artifact.publicKeyB64
        )

        XCTAssertFalse(result.valid)
        XCTAssertEqual(result.code, "clock_tamper")
    }

    func testInnerAndOuterKeyIdMustAgree() throws {
        let now = Int(Date().timeIntervalSince1970)
        let artifact = try makeSyntheticMachineFile(
            keyId: "outer-key",
            innerKeyId: "inner-key",
            iat: now - 60,
            exp: now + 86_400
        )

        let result = try sdk.verifyMachineFile(
            artifact.machineFile,
            publicKeyB64: artifact.publicKeyB64
        )

        XCTAssertFalse(result.valid)
        XCTAssertEqual(result.code, "invalid_machine_file_claims")
    }

    func testSignedLifetimeMustMatchItsWindow() throws {
        let now = Int(Date().timeIntervalSince1970)
        let artifact = try makeSyntheticMachineFile(
            iat: now - 60,
            exp: now + 86_400,
            ttl: 1
        )

        let result = try sdk.verifyMachineFile(
            artifact.machineFile,
            publicKeyB64: artifact.publicKeyB64
        )

        XCTAssertFalse(result.valid)
        XCTAssertEqual(result.code, "invalid_machine_file_claims")
    }

    func testZeroWidthWindowIsNeverAGrant() throws {
        let now = Int(Date().timeIntervalSince1970)
        let artifact = try makeSyntheticMachineFile(
            iat: now - 60,
            nbf: now + 86_400,
            exp: now + 86_400,
            ttl: 86_460,
            gracePeriod: 86_400
        )

        let result = try sdk.verifyMachineFile(
            artifact.machineFile,
            publicKeyB64: artifact.publicKeyB64
        )

        XCTAssertFalse(result.valid)
        XCTAssertEqual(result.code, "invalid_machine_file_claims")
    }

    func testMalformedArmorIsRejected() throws {
        let result = try sdk.verifyMachineFile(
            MachineFile(certificate: "-----BEGIN MACHINE FILE-----\nnot base64!\n-----END MACHINE FILE-----"),
            publicKeyB64: Self.fixture.publicKey
        )

        XCTAssertFalse(result.valid)
        XCTAssertEqual(result.code, "invalid_machine_file")
    }
}
