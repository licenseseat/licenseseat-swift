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

    func testNonFiniteRetryDelayDoesNotTrap() async throws {
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

        let _: EmptyResponse = try await apiClient.get(path: "/health")
        XCTAssertEqual(attempts, 2)
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
}

// MARK: - Helpers

private struct TestResponse: Codable, Equatable {
    let message: String
}
