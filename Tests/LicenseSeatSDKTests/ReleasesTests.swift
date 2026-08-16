//
//  ReleasesTests.swift
//  LicenseSeatSDKTests
//
//  Release discovery, download-token issuance, and query-string hardening.
//

import XCTest
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import LicenseSeat

/// The product every fixture and route in this file is scoped to. File-level
/// so it can serve as a default argument outside the main actor.
private let testProductSlug = "test-app"

/// Captures what the SDK actually put on the wire. The handler runs off the
/// main actor, so the recorded values are lock-protected.
private final class RequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var requests = [URLRequest]()

    func record(_ request: URLRequest) {
        lock.lock()
        requests.append(request)
        lock.unlock()
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return requests.count
    }

    var last: URLRequest? {
        lock.lock()
        defer { lock.unlock() }
        return requests.last
    }

    var lastComponents: URLComponents? {
        guard let url = last?.url else { return nil }
        return URLComponents(url: url, resolvingAgainstBaseURL: false)
    }

    var lastQueryItems: [URLQueryItem] { lastComponents?.queryItems ?? [] }

    var lastPath: String? { lastComponents?.percentEncodedPath }

    var lastBody: [String: Any] {
        guard let request = last else { return [:] }
        return MockURLProtocol.jsonBody(for: request)
    }
}

@MainActor
final class ReleasesTests: LicenseSeatTestCase {
    private var sdk: LicenseSeat!
    private var recorder: RequestRecorder!

    override func setUp() async throws {
        _ = URLProtocol.registerClass(MockURLProtocol.self)
        MockURLProtocol.reset()
        recorder = RequestRecorder()
        sdk = makeSDK()
    }

    // Sync teardown limited to nonisolated statics (the APIClientTests
    // pattern): a @MainActor suite cannot touch isolated state here without
    // tripping Swift 6 strict concurrency on the Linux lane, and the base
    // class finals both async overrides by design. Per-test isolation comes
    // from the UUID storage prefix, so skipping sdk.reset() leaks nothing
    // across tests.
    override func tearDown() {
        MockURLProtocol.reset()
        URLProtocol.unregisterClass(MockURLProtocol.self)
        super.tearDown()
    }

    // MARK: - Harness

    private func makeConfig(
        apiKey: String? = "unit-test",
        productSlug: String? = testProductSlug
    ) -> LicenseSeatConfig {
        LicenseSeatConfig(
            apiBaseUrl: "https://api.test.com",
            apiKey: apiKey,
            productSlug: productSlug,
            storagePrefix: "releases_test_\(UUID().uuidString)_",
            deviceIdentifier: "test-device",
            autoValidateInterval: 0,
            heartbeatInterval: 0,
            maxRetries: 0,
            telemetryEnabled: false
        )
    }

    private func makeSDK(config: LicenseSeatConfig? = nil) -> LicenseSeat {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let sdk = LicenseSeat(
            config: config ?? makeConfig(),
            urlSession: URLSession(configuration: configuration)
        )
        sdk.cache.clear()
        return sdk
    }

    private func makeAPIClient() -> APIClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        return APIClient(
            config: makeConfig(),
            session: URLSession(configuration: configuration)
        )
    }

    /// Respond with a fixed JSON object and record the request that asked for it.
    private func stub(_ payload: Any, status: Int = 200) {
        let recorder = self.recorder!
        MockURLProtocol.requestHandler = { request in
            recorder.record(request)
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: status,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, try JSONSerialization.data(withJSONObject: payload))
        }
    }

    // MARK: - Fixtures
    //
    // Field-for-field the shape the API serializes: `present_release` emits
    // object/version/channel/platform/published_at/product_slug, and
    // `render_list` wraps items in object/data/has_more/next_cursor.

    private func releasePayload(
        version: String = "2.1.0",
        channel: String = "stable",
        platform: String = "macos",
        productSlug: String = testProductSlug,
        publishedAt: Any = "2026-01-15T00:00:00Z",
        object: String = "release"
    ) -> [String: Any] {
        [
            "object": object,
            "version": version,
            "channel": channel,
            "platform": platform,
            "published_at": publishedAt,
            "product_slug": productSlug
        ]
    }

    private func releaseListPayload(
        _ releases: [[String: Any]],
        hasMore: Bool = false,
        nextCursor: Any = NSNull()
    ) -> [String: Any] {
        [
            "object": "list",
            "data": releases,
            "has_more": hasMore,
            "next_cursor": nextCursor
        ]
    }

    private func downloadTokenPayload(
        token: String = "eyJhbGciOiJFZERTQSIsInR5cCI6IkpXVCJ9.payload.signature",
        expiresIn: TimeInterval = 300,
        object: String = "download_token"
    ) -> [String: Any] {
        [
            "object": object,
            "token": token,
            "expires_at": ISO8601DateFormatter().string(
                from: Date().addingTimeInterval(expiresIn)
            )
        ]
    }

    // MARK: - Query String Construction

    func testQueryItemsAreAppendedToTheEndpointURL() throws {
        let client = makeAPIClient()
        let baseURL = try XCTUnwrap(client.validatedBaseURL())

        let url = client.endpointURL(
            baseURL: baseURL,
            pathComponents: ["products", "test-app", "releases"],
            queryItems: [
                URLQueryItem(name: "channel", value: "beta"),
                URLQueryItem(name: "limit", value: "5")
            ]
        )

        XCTAssertEqual(
            url?.absoluteString,
            "https://api.test.com/products/test-app/releases?channel=beta&limit=5"
        )
    }

    func testNoQueryItemsLeavesTheURLUnchanged() throws {
        let client = makeAPIClient()
        let baseURL = try XCTUnwrap(client.validatedBaseURL())

        let url = client.endpointURL(
            baseURL: baseURL,
            pathComponents: ["products", "test-app", "releases", "latest"]
        )

        XCTAssertEqual(
            url?.absoluteString,
            "https://api.test.com/products/test-app/releases/latest"
        )
        XCTAssertNil(url?.query)
    }

    func testQueryBuilderRejectsKeysOutsideTheAllowlist() {
        let client = makeAPIClient()

        XCTAssertNil(client.encodedQuery([
            URLQueryItem(name: "license_key", value: "LS-SECRET")
        ]))
        XCTAssertNil(client.encodedQuery([
            URLQueryItem(name: "channel", value: "beta"),
            URLQueryItem(name: "admin", value: "1")
        ]))
    }

    func testQueryBuilderRejectsRepeatedKeys() {
        let client = makeAPIClient()

        XCTAssertNil(client.encodedQuery([
            URLQueryItem(name: "channel", value: "stable"),
            URLQueryItem(name: "channel", value: "beta")
        ]))
    }

    func testQueryBuilderRejectsMoreItemsThanAllowedKeys() {
        let client = makeAPIClient()

        XCTAssertNil(client.encodedQuery([
            URLQueryItem(name: "channel", value: "beta"),
            URLQueryItem(name: "platform", value: "macos"),
            URLQueryItem(name: "limit", value: "5"),
            URLQueryItem(name: "channel", value: "alpha")
        ]))
    }

    func testQueryBuilderRejectsMissingEmptyAndUntrimmedValues() {
        let client = makeAPIClient()

        XCTAssertNil(client.encodedQuery([URLQueryItem(name: "channel", value: nil)]))
        XCTAssertNil(client.encodedQuery([URLQueryItem(name: "channel", value: "")]))
        XCTAssertNil(client.encodedQuery([URLQueryItem(name: "channel", value: " beta")]))
    }

    func testQueryBuilderRejectsControlCharactersAndOversizedValues() {
        let client = makeAPIClient()

        XCTAssertNil(client.encodedQuery([
            URLQueryItem(name: "channel", value: "beta\u{0A}injected")
        ]))
        XCTAssertNil(client.encodedQuery([
            URLQueryItem(name: "platform", value: String(repeating: "a", count: 256))
        ]))
        XCTAssertNotNil(client.encodedQuery([
            URLQueryItem(name: "platform", value: String(repeating: "a", count: 255))
        ]))
    }

    func testQueryBuilderEncodesReservedCharactersIntoASingleValue() throws {
        let client = makeAPIClient()
        let baseURL = try XCTUnwrap(client.validatedBaseURL())

        // A value that tries to open a second parameter must survive as one
        // opaque value, not as an extra pair the server would read.
        let url = try XCTUnwrap(client.endpointURL(
            baseURL: baseURL,
            pathComponents: ["products", "test-app", "releases"],
            queryItems: [URLQueryItem(name: "channel", value: "beta&limit=100")]
        ))

        XCTAssertEqual(url.query, "channel=beta%26limit%3D100")
        let items = try XCTUnwrap(
            URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
        )
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.first?.value, "beta&limit=100")
    }

    // MARK: - Latest Release

    func testGetLatestReleaseDecodesTheServerShape() async throws {
        stub(releasePayload())

        let release = try await sdk.getLatestRelease()

        XCTAssertEqual(release.object, "release")
        XCTAssertEqual(release.version, "2.1.0")
        XCTAssertEqual(release.channel, "stable")
        XCTAssertEqual(release.platform, "macos")
        XCTAssertEqual(release.productSlug, testProductSlug)
        XCTAssertEqual(
            release.publishedAt,
            ISO8601DateFormatter().date(from: "2026-01-15T00:00:00Z")
        )
        XCTAssertEqual(recorder.lastPath, "/products/test-app/releases/latest")
        XCTAssertEqual(recorder.last?.httpMethod, "GET")
        XCTAssertTrue(recorder.lastQueryItems.isEmpty)
    }

    func testGetLatestReleaseSendsChannelAndPlatformFilters() async throws {
        stub(releasePayload(channel: "beta", platform: "macos"))

        _ = try await sdk.getLatestRelease(channel: "beta", platform: "macos")

        XCTAssertEqual(recorder.lastPath, "/products/test-app/releases/latest")
        XCTAssertEqual(
            recorder.lastQueryItems,
            [
                URLQueryItem(name: "channel", value: "beta"),
                URLQueryItem(name: "platform", value: "macos")
            ]
        )
    }

    func testGetLatestReleaseAcceptsAnAnyPlatformRelease() async throws {
        // The server's by_platform scope matches "platform = ? OR 'any'", so a
        // cross-platform release is a correct answer to a filtered request.
        stub(releasePayload(platform: "any"))

        let release = try await sdk.getLatestRelease(platform: "macos")

        XCTAssertEqual(release.platform, "any")
    }

    func testGetLatestReleaseRejectsAnotherProductsRelease() async {
        stub(releasePayload(productSlug: "other-app"))

        await assertAPIError(code: "release_response_mismatch") {
            _ = try await self.sdk.getLatestRelease()
        }
    }

    func testGetLatestReleaseRejectsAChannelItDidNotAskFor() async {
        stub(releasePayload(channel: "alpha"))

        await assertAPIError(code: "release_response_mismatch") {
            _ = try await self.sdk.getLatestRelease(channel: "beta")
        }
    }

    func testGetLatestReleaseRejectsAPlatformItDidNotAskFor() async {
        stub(releasePayload(platform: "windows"))

        await assertAPIError(code: "release_response_mismatch") {
            _ = try await self.sdk.getLatestRelease(platform: "macos")
        }
    }

    func testGetLatestReleaseRejectsUnknownChannelsAndPlatforms() async {
        stub(releasePayload(channel: "nightly"))
        await assertAPIError(code: "invalid_release_response") {
            _ = try await self.sdk.getLatestRelease()
        }

        stub(releasePayload(platform: "solaris"))
        await assertAPIError(code: "invalid_release_response") {
            _ = try await self.sdk.getLatestRelease()
        }
    }

    func testGetLatestReleaseRejectsAWrongObjectType() async {
        stub(releasePayload(object: "license"))

        await assertAPIError(code: "invalid_release_response") {
            _ = try await self.sdk.getLatestRelease()
        }
    }

    func testGetLatestReleaseRejectsAnUnpublishedOrFuturePublication() async {
        stub(releasePayload(publishedAt: NSNull()))
        await assertAPIError(code: "invalid_release_response") {
            _ = try await self.sdk.getLatestRelease()
        }

        let future = ISO8601DateFormatter().string(from: Date().addingTimeInterval(3600))
        stub(releasePayload(publishedAt: future))
        await assertAPIError(code: "invalid_release_response") {
            _ = try await self.sdk.getLatestRelease()
        }
    }

    func testReleaseFiltersAreValidatedBeforeAnyRequest() async {
        stub(releasePayload())

        await assertAPIError(code: "invalid_release_filter") {
            _ = try await self.sdk.getLatestRelease(channel: "nightly")
        }
        await assertAPIError(code: "invalid_release_filter") {
            _ = try await self.sdk.getLatestRelease(platform: "solaris")
        }
        XCTAssertEqual(recorder.count, 0)
    }

    func testGetLatestReleaseRequiresAProductSlug() async {
        sdk = makeSDK(config: makeConfig(productSlug: nil))
        stub(releasePayload())

        do {
            _ = try await sdk.getLatestRelease()
            XCTFail("Expected productSlugRequired")
        } catch let error as LicenseSeatError {
            XCTAssertEqual(error, .productSlugRequired)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertEqual(recorder.count, 0)
    }

    // MARK: - Release List

    func testListReleasesDecodesTheListEnvelope() async throws {
        stub(releaseListPayload([
            releasePayload(version: "2.1.0"),
            releasePayload(version: "2.0.0", publishedAt: "2025-11-02T09:30:00Z")
        ]))

        let releases = try await sdk.listReleases()

        XCTAssertEqual(releases.map(\.version), ["2.1.0", "2.0.0"])
        XCTAssertEqual(recorder.lastPath, "/products/test-app/releases")
        XCTAssertTrue(recorder.lastQueryItems.isEmpty)
    }

    func testListReleasesSendsChannelPlatformAndLimit() async throws {
        stub(releaseListPayload([releasePayload(channel: "beta")]))

        _ = try await sdk.listReleases(channel: "beta", platform: "macos", limit: 5)

        XCTAssertEqual(
            recorder.lastQueryItems,
            [
                URLQueryItem(name: "channel", value: "beta"),
                URLQueryItem(name: "platform", value: "macos"),
                URLQueryItem(name: "limit", value: "5")
            ]
        )
    }

    func testListReleasesAcceptsATruncatedPageWithoutACursor() async throws {
        // The releases controller reports has_more from the page count but
        // always renders next_cursor as null, so the two must not be coupled.
        stub(releaseListPayload([releasePayload()], hasMore: true))

        let releases = try await sdk.listReleases(limit: 1)

        XCTAssertEqual(releases.count, 1)
    }

    func testListReleasesAcceptsABareArrayResponse() async throws {
        stub([releasePayload()])

        let releases = try await sdk.listReleases()

        XCTAssertEqual(releases.count, 1)
    }

    func testListReleasesRejectsAWrongEnvelopeType() async {
        var payload = releaseListPayload([releasePayload()])
        payload["object"] = "release"
        stub(payload)

        await assertAPIError(code: "invalid_release_response") {
            _ = try await self.sdk.listReleases()
        }
    }

    func testListReleasesRejectsAnItemFromAnotherProduct() async {
        stub(releaseListPayload([
            releasePayload(),
            releasePayload(version: "1.0.0", productSlug: "other-app")
        ]))

        await assertAPIError(code: "release_response_mismatch") {
            _ = try await self.sdk.listReleases()
        }
    }

    func testListReleasesRejectsAnOutOfRangeLimit() async {
        stub(releaseListPayload([releasePayload()]))

        await assertAPIError(code: "invalid_release_filter") {
            _ = try await self.sdk.listReleases(limit: 0)
        }
        await assertAPIError(code: "invalid_release_filter") {
            _ = try await self.sdk.listReleases(limit: 101)
        }
        XCTAssertEqual(recorder.count, 0)
    }

    // MARK: - Download Token

    func testGenerateDownloadTokenPostsToTheVersionedRoute() async throws {
        stub(downloadTokenPayload())

        let token = try await sdk.generateDownloadToken(
            version: "2.1.0",
            licenseKey: "LS-ABCD-1234",
            platform: "macos"
        )

        XCTAssertEqual(token.object, "download_token")
        XCTAssertFalse(token.token.isEmpty)
        XCTAssertNotNil(token.expiresAt)
        XCTAssertEqual(recorder.last?.httpMethod, "POST")
        XCTAssertEqual(
            recorder.lastPath,
            "/products/test-app/releases/2.1.0/download_token"
        )
        XCTAssertTrue(recorder.lastQueryItems.isEmpty)

        // The license key is a credential and belongs in the body only.
        let body = recorder.lastBody
        XCTAssertEqual(body["license_key"] as? String, "LS-ABCD-1234")
        XCTAssertEqual(body["platform"] as? String, "macos")
        XCTAssertFalse(recorder.last?.url?.absoluteString.contains("LS-ABCD-1234") ?? true)
    }

    func testGenerateDownloadTokenOmitsAnUnsetPlatform() async throws {
        stub(downloadTokenPayload())

        _ = try await sdk.generateDownloadToken(
            version: "2.1.0",
            licenseKey: "LS-ABCD-1234"
        )

        XCTAssertNil(recorder.lastBody["platform"])
    }

    func testGenerateDownloadTokenKeepsAVersionInsideOnePathSegment() async throws {
        stub(downloadTokenPayload())

        _ = try await sdk.generateDownloadToken(
            version: "2.1.0/../../admin",
            licenseKey: "LS-ABCD-1234"
        )

        XCTAssertEqual(
            recorder.lastPath,
            "/products/test-app/releases/2.1.0%2F..%2F..%2Fadmin/download_token"
        )
    }

    func testGenerateDownloadTokenRedactsTheTokenInDescriptions() async throws {
        stub(downloadTokenPayload(token: "super-secret-token-value"))

        let token = try await sdk.generateDownloadToken(
            version: "2.1.0",
            licenseKey: "LS-ABCD-1234"
        )

        XCTAssertFalse("\(token)".contains("super-secret-token-value"))
        XCTAssertFalse(String(reflecting: token).contains("super-secret-token-value"))
        XCTAssertEqual(token.token, "super-secret-token-value")
    }

    func testGenerateDownloadTokenRejectsAnExpiredOrOverlongToken() async {
        stub(downloadTokenPayload(expiresIn: -60))
        await assertAPIError(code: "invalid_download_token_response") {
            _ = try await self.sdk.generateDownloadToken(
                version: "2.1.0",
                licenseKey: "LS-ABCD-1234"
            )
        }

        stub(downloadTokenPayload(expiresIn: 31 * 24 * 60 * 60))
        await assertAPIError(code: "invalid_download_token_response") {
            _ = try await self.sdk.generateDownloadToken(
                version: "2.1.0",
                licenseKey: "LS-ABCD-1234"
            )
        }
    }

    func testGenerateDownloadTokenRejectsAShortTokenOrWrongObject() async {
        stub(downloadTokenPayload(token: "short"))
        await assertAPIError(code: "invalid_download_token_response") {
            _ = try await self.sdk.generateDownloadToken(
                version: "2.1.0",
                licenseKey: "LS-ABCD-1234"
            )
        }

        stub(downloadTokenPayload(object: "license"))
        await assertAPIError(code: "invalid_download_token_response") {
            _ = try await self.sdk.generateDownloadToken(
                version: "2.1.0",
                licenseKey: "LS-ABCD-1234"
            )
        }
    }

    func testGenerateDownloadTokenRejectsMalformedArgumentsBeforeAnyRequest() async {
        stub(downloadTokenPayload())

        await assertAPIError(code: "invalid_release_filter") {
            _ = try await self.sdk.generateDownloadToken(
                version: "",
                licenseKey: "LS-ABCD-1234"
            )
        }
        await assertAPIError(code: "invalid_release_filter") {
            _ = try await self.sdk.generateDownloadToken(
                version: "2.1.0",
                licenseKey: "LS-ABCD-1234",
                platform: "solaris"
            )
        }
        await assertAPIError(code: "invalid_identity") {
            _ = try await self.sdk.generateDownloadToken(
                version: "2.1.0",
                licenseKey: " leading-space"
            )
        }
        XCTAssertEqual(recorder.count, 0)
    }

    func testGenerateDownloadTokenRequiresAnAPIKey() async {
        sdk = makeSDK(config: makeConfig(apiKey: nil))
        stub(downloadTokenPayload())

        do {
            _ = try await sdk.generateDownloadToken(
                version: "2.1.0",
                licenseKey: "LS-ABCD-1234"
            )
            XCTFail("Expected apiKeyRequired")
        } catch let error as LicenseSeatError {
            XCTAssertEqual(error, .apiKeyRequired)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertEqual(recorder.count, 0)
    }

    // MARK: - Assertions

    private func assertAPIError(
        code expectedCode: String,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ operation: () async throws -> Void
    ) async {
        do {
            try await operation()
            XCTFail("Expected APIError with code \(expectedCode)", file: file, line: line)
        } catch let error as APIError {
            XCTAssertEqual(error.code, expectedCode, file: file, line: line)
        } catch {
            XCTFail("Unexpected error: \(error)", file: file, line: line)
        }
    }
}
