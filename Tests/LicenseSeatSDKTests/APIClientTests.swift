//
//  APIClientTests.swift
//  LicenseSeatSDKTests
//
//  Created by LicenseSeat on 2025.
//

import XCTest
#if canImport(CryptoKit)
import CryptoKit
#elseif canImport(Crypto)
import Crypto
#endif
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import LicenseSeat

@MainActor
final class APIClientTests: LicenseSeatTestCase {
    private var config: LicenseSeatConfig!
    private var apiClient: APIClient!
    private var requestCount: Int!
    
    override func setUp() async throws {
        _ = URLProtocol.registerClass(MockURLProtocol.self)
        MockURLProtocol.reset()
        requestCount = 0
        
        config = LicenseSeatConfig(
            apiBaseUrl: "https://api.test.com",
            apiKey: "test-key",
            storagePrefix: "api_client_test_",
            maxRetries: 2,
            retryDelay: 0.05, // 50 ms for fast tests
            debug: true
        )
        let conf = URLSessionConfiguration.ephemeral
        conf.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: conf)
        apiClient = APIClient(config: config, session: session)
    }
    
    override func tearDown() {
        URLProtocol.unregisterClass(MockURLProtocol.self)
        super.tearDown()
    }

    private func makeClient(config: LicenseSeatConfig) -> APIClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        return APIClient(
            config: config,
            session: URLSession(configuration: configuration)
        )
    }
    
    func testSuccessfulGETRequest() async throws {
        // Prepare stub
        let expected = TestResponse(message: "pong")
        let data = try JSONEncoder().encode(expected)
        MockURLProtocol.requestHandler = { request in
            self.requestCount += 1
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, data)
        }
        
        // Perform request
        let result: TestResponse = try await apiClient.get(path: "/ping")
        
        // Verify
        XCTAssertEqual(result.message, expected.message)
        XCTAssertEqual(requestCount, 1)
    }
    
    func testRetryOn5xxThenSuccess() async throws {
        // First attempt 502, second attempt 200
        let expected = TestResponse(message: "ok")
        let data = try JSONEncoder().encode(expected)
        var attempts = 0
        MockURLProtocol.requestHandler = { request in
            attempts += 1
            if attempts == 1 {
                let failResponse = HTTPURLResponse(url: request.url!, statusCode: 502, httpVersion: nil, headerFields: nil)!
                return (failResponse, Data("{\"error\":\"bad\"}".utf8))
            }
            let success = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
            return (success, data)
        }
        
        let result: TestResponse = try await apiClient.get(path: "/unstable")
        XCTAssertEqual(result.message, expected.message)
        XCTAssertEqual(attempts, 2)
    }
    
    func testNoRetryOn400() async {
        var attempts = 0
        MockURLProtocol.requestHandler = { request in
            attempts += 1
            let res = HTTPURLResponse(url: request.url!, statusCode: 400, httpVersion: nil, headerFields: nil)!
            return (res, Data("{\"error\":\"bad\"}".utf8))
        }
        do {
            let _: TestResponse = try await apiClient.get(path: "/client-error")
            XCTFail("Should have thrown")
        } catch {
            // expected
        }
        XCTAssertEqual(attempts, 1)
    }

    func testCancelledTransportIsNotRetriedOrReportedAsOffline() async {
        var attempts = 0
        var connectivityChanges: [Bool] = []
        apiClient.onNetworkStatusChange = { connectivityChanges.append($0) }
        MockURLProtocol.requestHandler = { _ in
            attempts += 1
            throw URLError(.cancelled)
        }

        do {
            let _: TestResponse = try await apiClient.get(path: "/cancelled")
            XCTFail("Expected cancellation")
        } catch let error as URLError {
            XCTAssertEqual(error.code, .cancelled)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertEqual(attempts, 1)
        XCTAssertTrue(connectivityChanges.isEmpty)
    }
    
    func testAuthHeaderPresent() async throws {
        MockURLProtocol.requestHandler = { request in
            let authHeader = request.value(forHTTPHeaderField: "Authorization")
            XCTAssertEqual(authHeader, "Bearer test-key")
            let res = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (res, Data("{}".utf8))
        }
        let _: EmptyResponse = try await apiClient.get(path: "/auth-test")
    }

    func testTypedResponseWithEmptySuccessBodyThrowsInsteadOfTrapping() async {
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 204,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, Data())
        }

        do {
            let _: TestResponse = try await apiClient.get(path: "/unexpected-empty-response")
            XCTFail("A typed response must not accept an empty body")
        } catch is DecodingError {
            // Expected: malformed successful responses are surfaced as errors,
            // never as an unconditional generic force-cast crash.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testRequestPreservesConfiguredBasePathAndNormalizesEndpointSlash() async throws {
        config.apiBaseUrl = "https://api.test.com/api/v1/"
        let conf = URLSessionConfiguration.ephemeral
        conf.protocolClasses = [MockURLProtocol.self]
        apiClient = APIClient(config: config, session: URLSession(configuration: conf))

        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.url?.absoluteString, "https://api.test.com/api/v1/ping")
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, Data("{\"message\":\"pong\"}".utf8))
        }

        let response: TestResponse = try await apiClient.get(path: "/ping")
        XCTAssertEqual(response.message, "pong")
    }

    func testOpaquePathComponentsCannotChangeRouteStructure() async throws {
        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(
                request.url?.absoluteString,
                "https://api.test.com/signing_keys/..%2Fhealth%3Fadmin=1%23fragment"
            )
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, Data())
        }

        let _: EmptyResponse = try await apiClient.get(
            pathComponents: ["signing_keys", "../health?admin=1#fragment"]
        )
    }

    func testRejectsPlainHTTPForNonLoopbackHostBeforeSendingRequest() async {
        config.apiBaseUrl = "http://api.example.com/api/v1"
        let conf = URLSessionConfiguration.ephemeral
        conf.protocolClasses = [MockURLProtocol.self]
        apiClient = APIClient(config: config, session: URLSession(configuration: conf))
        var connectivityChanges = [Bool]()
        apiClient.onNetworkStatusChange = { connectivityChanges.append($0) }
        MockURLProtocol.requestHandler = { _ in
            XCTFail("An invalid non-TLS request must not reach URLSession")
            throw URLError(.badURL)
        }

        do {
            let _: EmptyResponse = try await apiClient.get(path: "/health")
            XCTFail("Expected an invalid base URL error")
        } catch let error as APIError {
            XCTAssertEqual(error.status, 0)
            XCTAssertEqual(error.code, "invalid_base_url")
            XCTAssertEqual(error.message, "Invalid API base URL")
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertTrue(connectivityChanges.isEmpty)
    }

    func testHTTPTimeoutMarksTransportOffline() async {
        var connectivityChanges = [Bool]()
        apiClient.onNetworkStatusChange = { connectivityChanges.append($0) }
        MockURLProtocol.requestHandler = { request in
            let payload = ["error": ["code": "request_timeout", "message": "Timed out"]]
            return (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 408,
                    httpVersion: nil,
                    headerFields: nil
                )!,
                try JSONSerialization.data(withJSONObject: payload)
            )
        }

        do {
            let _: EmptyResponse = try await apiClient.get(path: "/slow")
            XCTFail("Expected request timeout")
        } catch let error as APIError {
            XCTAssertEqual(error.status, 408)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertEqual(connectivityChanges, [false])
    }

    func testAllowsPlainHTTPForLoopbackDevelopmentServer() async throws {
        config.apiBaseUrl = "http://127.0.0.1:3000/api/v1"
        let conf = URLSessionConfiguration.ephemeral
        conf.protocolClasses = [MockURLProtocol.self]
        apiClient = APIClient(config: config, session: URLSession(configuration: conf))

        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.url?.absoluteString, "http://127.0.0.1:3000/api/v1/health")
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, Data())
        }

        let _: EmptyResponse = try await apiClient.get(path: "/health")
    }

    func testNegativeRetryCountDoesNotTrapOrRetry() async {
        config.maxRetries = -1
        let conf = URLSessionConfiguration.ephemeral
        conf.protocolClasses = [MockURLProtocol.self]
        apiClient = APIClient(config: config, session: URLSession(configuration: conf))
        var attempts = 0
        MockURLProtocol.requestHandler = { request in
            attempts += 1
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 503,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, Data())
        }

        do {
            let _: EmptyResponse = try await apiClient.get(path: "/health")
            XCTFail("Expected a server error")
        } catch let error as APIError {
            XCTAssertEqual(error.status, 503)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertEqual(attempts, 1)
    }

    func testNonFiniteRetryDelayIsRejectedBeforeTransport() async {
        config.maxRetries = 1
        config.retryDelay = .infinity
        let conf = URLSessionConfiguration.ephemeral
        conf.protocolClasses = [MockURLProtocol.self]
        apiClient = APIClient(config: config, session: URLSession(configuration: conf))
        var attempts = 0
        MockURLProtocol.requestHandler = { request in
            attempts += 1
            let status = attempts == 1 ? 503 : 200
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: status,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, status == 200 ? Data() : Data())
        }

        do {
            let _: EmptyResponse = try await apiClient.get(path: "/health")
            XCTFail("Expected invalid retry configuration to be rejected")
        } catch let error as APIError {
            XCTAssertEqual(error.code, "invalid_retry_configuration")
            XCTAssertFalse(error.isRetryable)
            XCTAssertFalse(error.isNetworkError)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertEqual(attempts, 0)
    }

    func testRejectsCredentialsQueryAndFragmentInBaseURL() async {
        for invalidURL in [
            "https://user:password@api.example.com/api/v1",
            "https://api.example.com/api/v1?tenant=other",
            "https://api.example.com/api/v1#fragment"
        ] {
            config.apiBaseUrl = invalidURL
            let conf = URLSessionConfiguration.ephemeral
            conf.protocolClasses = [MockURLProtocol.self]
            apiClient = APIClient(config: config, session: URLSession(configuration: conf))

            do {
                let _: EmptyResponse = try await apiClient.get(path: "/health")
                XCTFail("Expected \(invalidURL) to be rejected")
            } catch let error as APIError {
                XCTAssertEqual(error.status, 0)
                XCTAssertEqual(error.message, "Invalid API base URL")
            } catch {
                XCTFail("Unexpected error for \(invalidURL): \(error)")
            }
        }
    }

    func testCustomHeadersCannotOverrideAuthenticationOrJSONBoundary() async throws {
        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(
                request.value(forHTTPHeaderField: "Authorization"),
                "Bearer test-key"
            )
            XCTAssertEqual(
                request.value(forHTTPHeaderField: "Content-Type"),
                "application/json"
            )
            XCTAssertEqual(
                request.value(forHTTPHeaderField: "Accept"),
                "application/json"
            )
            XCTAssertEqual(
                request.value(forHTTPHeaderField: "X-Application-Header"),
                "allowed"
            )
            XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
            XCTAssertNotEqual(
                request.value(forHTTPHeaderField: "Host"),
                "attacker.example"
            )
            XCTAssertNotEqual(
                request.value(forHTTPHeaderField: "Content-Length"),
                "999999"
            )
            return (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 204,
                    httpVersion: nil,
                    headerFields: nil
                )!,
                Data()
            )
        }

        let _: EmptyResponse = try await apiClient.get(
            path: "/protected-headers",
            headers: [
                "authorization": "Bearer attacker",
                "CONTENT-TYPE": "text/plain",
                "Accept": "*/*",
                "Cookie": "session=attacker",
                "Host": "attacker.example",
                "Content-Length": "999999",
                "X-Application-Header": "allowed"
            ]
        )
    }

    func testInvalidAPIKeyOrCustomHeaderCannotReachTransport() async {
        var attempts = 0
        MockURLProtocol.requestHandler = { request in
            attempts += 1
            return (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 204,
                    httpVersion: nil,
                    headerFields: nil
                )!,
                Data()
            )
        }

        for invalidAPIKey in ["pk_test_bad\r\nInjected: yes", " key"] {
            config.apiKey = invalidAPIKey
            apiClient = makeClient(config: config)
            do {
                let _: EmptyResponse = try await apiClient.get(path: "/headers")
                XCTFail("Invalid API keys must fail before transport")
            } catch let error as APIError {
                XCTAssertEqual(error.code, "invalid_headers")
                XCTAssertFalse(error.isNetworkError)
                XCTAssertFalse(error.isRetryable)
            } catch {
                XCTFail("Unexpected error: \(error)")
            }
        }

        config.apiKey = "test-key"
        apiClient = makeClient(config: config)
        for headers in [["Bad:Name": "value"], ["X-Test": "line\nvalue"]] {
            do {
                let _: EmptyResponse = try await apiClient.get(
                    path: "/headers",
                    headers: headers
                )
                XCTFail("Invalid custom headers must fail before transport")
            } catch let error as APIError {
                XCTAssertEqual(error.code, "invalid_headers")
                XCTAssertFalse(error.isNetworkError)
                XCTAssertFalse(error.isRetryable)
            } catch {
                XCTFail("Unexpected error: \(error)")
            }
        }
        XCTAssertEqual(attempts, 0)
    }

    func testDuplicateResponseMembersAreRejectedBeforeDecoding() async {
        MockURLProtocol.requestHandler = { request in
            (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!,
                Data(#"{"message":"denied","message":"granted"}"#.utf8)
            )
        }

        do {
            let _: TestResponse = try await apiClient.get(path: "/ambiguous")
            XCTFail("Ambiguous JSON must not be decoded")
        } catch let error as StrictJSONError {
            XCTAssertEqual(error, .duplicateKey)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testOversizedActualOrDeclaredResponseIsRejected() async {
        let oversized = Data(repeating: 0x20, count: 2 * 1024 * 1024 + 1)
        var useDeclaredLength = false
        var attempts = 0
        MockURLProtocol.requestHandler = { request in
            attempts += 1
            let headers = useDeclaredLength
                ? ["Content-Length": String(2 * 1024 * 1024 + 1)]
                : nil
            return (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: headers
                )!,
                useDeclaredLength ? Data("{}".utf8) : oversized
            )
        }

        for declaredLengthOnly in [false, true] {
            useDeclaredLength = declaredLengthOnly
            do {
                let _: TestResponse = try await apiClient.get(path: "/large")
                XCTFail("Oversized responses must be rejected")
            } catch let error as APIError {
                XCTAssertEqual(error.code, "response_too_large")
                XCTAssertFalse(error.isNetworkError)
                XCTAssertFalse(error.isRetryable)
            } catch {
                XCTFail("Unexpected error: \(error)")
            }
        }
        XCTAssertEqual(attempts, 2)
    }

    func testSDKOwnedSessionStreamsThroughTheResponseLimit() async {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        apiClient = APIClient(
            config: config,
            ownedSessionConfiguration: configuration
        )
        var attempts = 0
        MockURLProtocol.requestHandler = { request in
            attempts += 1
            return (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )!,
                Data(repeating: 0x20, count: 2 * 1024 * 1024 + 1)
            )
        }

        do {
            let _: TestResponse = try await apiClient.get(path: "/stream-limit")
            XCTFail("SDK-owned sessions must cancel oversized streamed responses")
        } catch let error as APIError {
            XCTAssertEqual(error.code, "response_too_large")
            XCTAssertFalse(error.isNetworkError)
            XCTAssertFalse(error.isRetryable)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertEqual(attempts, 1)
    }

    func testSDKOwnedSessionDelegateRejectsRedirectReplay() {
        let delegate = BoundedSessionDelegate()
        let session = URLSession(
            configuration: .ephemeral,
            delegate: delegate,
            delegateQueue: nil
        )
        defer { session.invalidateAndCancel() }

        let initialURL = URL(string: "https://api.test.com/license")!
        let redirectURL = URL(string: "https://attacker.test/capture")!
        let task = session.dataTask(with: initialURL)
        let response = HTTPURLResponse(
            url: initialURL,
            statusCode: 307,
            httpVersion: nil,
            headerFields: ["Location": redirectURL.absoluteString]
        )!

        var replayedRequest: URLRequest?
        delegate.urlSession(
            session,
            task: task,
            willPerformHTTPRedirection: response,
            newRequest: URLRequest(url: redirectURL)
        ) { request in
            replayedRequest = request
        }
        XCTAssertNil(replayedRequest)
    }

    func testMismatchedFinalResponseURLCannotGrantAuthority() async {
        MockURLProtocol.requestHandler = { _ in
            (
                HTTPURLResponse(
                    url: URL(string: "https://attacker.example/response")!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )!,
                Data(#"{"message":"forged"}"#.utf8)
            )
        }

        do {
            let _: TestResponse = try await apiClient.get(path: "/expected")
            XCTFail("A response for another URL must be rejected")
        } catch let error as APIError {
            XCTAssertEqual(error.code, "unexpected_response_url")
            XCTAssertFalse(error.isRetryable)
            XCTAssertFalse(error.isNetworkError)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testRetryCountIsCappedAtTen() async {
        config.maxRetries = .max
        config.retryDelay = 0
        let conf = URLSessionConfiguration.ephemeral
        conf.protocolClasses = [MockURLProtocol.self]
        apiClient = APIClient(
            config: config,
            session: URLSession(configuration: conf)
        )
        var attempts = 0
        MockURLProtocol.requestHandler = { request in
            attempts += 1
            return (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 503,
                    httpVersion: nil,
                    headerFields: nil
                )!,
                Data(#"{"error":{"code":"unavailable"}}"#.utf8)
            )
        }

        do {
            let _: EmptyResponse = try await apiClient.get(path: "/retry-cap")
            XCTFail("Expected the server failure")
        } catch let error as APIError {
            XCTAssertEqual(error.status, 503)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertEqual(attempts, 11)
    }

    func testOversizedRequestIsRejectedBeforeTransport() async {
        var attempts = 0
        MockURLProtocol.requestHandler = { request in
            attempts += 1
            return (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 204,
                    httpVersion: nil,
                    headerFields: nil
                )!,
                Data()
            )
        }

        do {
            let _: EmptyResponse = try await apiClient.post(
                pathComponents: ["oversized"],
                body: ["value": String(repeating: "x", count: 1024 * 1024)]
            )
            XCTFail("Oversized requests must be rejected")
        } catch let error as APIError {
            XCTAssertEqual(error.code, "request_too_large")
            XCTAssertFalse(error.isRetryable)
            XCTAssertFalse(error.isNetworkError)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertEqual(attempts, 0)
    }

    func testAmbiguousErrorJSONIsNotReflectedAsAuthoritativeCode() async {
        MockURLProtocol.requestHandler = { request in
            (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 403,
                    httpVersion: nil,
                    headerFields: nil
                )!,
                Data(
                    #"{"error":{"code":"forbidden","code":"license_revoked"}}"#
                        .utf8
                )
            )
        }

        do {
            let _: EmptyResponse = try await apiClient.get(path: "/error")
            XCTFail("Expected an API error")
        } catch let error as APIError {
            XCTAssertEqual(error.status, 403)
            XCTAssertNil(error.code)
            XCTAssertEqual(error.message, "Request failed")
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testConfiguredRequestTimeoutReachesOwnedSessionConfiguration() {
        let defaultConfiguration = APIClient.ownedSessionConfiguration(
            for: LicenseSeatConfig.default
        )
        XCTAssertEqual(LicenseSeatConfig.default.requestTimeout, 30)
        XCTAssertEqual(defaultConfiguration.timeoutIntervalForRequest, 30)
        XCTAssertEqual(defaultConfiguration.timeoutIntervalForResource, 60)

        let customConfiguration = APIClient.ownedSessionConfiguration(
            for: LicenseSeatConfig(requestTimeout: 12)
        )
        XCTAssertEqual(customConfiguration.timeoutIntervalForRequest, 12)
        XCTAssertEqual(customConfiguration.timeoutIntervalForResource, 24)

        // Cookies, caching, and the rest of the transport policy survive the
        // extracted builder.
        XCTAssertFalse(customConfiguration.httpShouldSetCookies)
        XCTAssertEqual(customConfiguration.httpCookieAcceptPolicy, .never)
        XCTAssertNil(customConfiguration.urlCache)
        XCTAssertEqual(
            customConfiguration.requestCachePolicy,
            .reloadIgnoringLocalCacheData
        )
    }

    func testInvalidRequestTimeoutFallsBackToTheDefault() {
        let invalidTimeouts: [TimeInterval] = [0, -5, .infinity, .nan, 301]

        for timeout in invalidTimeouts {
            let config = LicenseSeatConfig(requestTimeout: timeout)
            XCTAssertEqual(
                config.resolvedRequestTimeout,
                30,
                "requestTimeout \(timeout) must fall back to the default"
            )
            let configuration = APIClient.ownedSessionConfiguration(for: config)
            XCTAssertEqual(configuration.timeoutIntervalForRequest, 30)
            XCTAssertEqual(configuration.timeoutIntervalForResource, 60)
        }
    }
}

// MARK: - Helpers

private struct TestResponse: Codable, Equatable {
    let message: String
}
