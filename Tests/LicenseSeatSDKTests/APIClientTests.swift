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
@testable import LicenseSeatSDK

final class APIClientTests: XCTestCase {
    private var config: LicenseSeatConfig!
    private var apiClient: APIClient!
    private var requestCount: Int!
    
    override func setUp() {
        super.setUp()
        URLProtocol.registerClass(MockURLProtocol.self)
        MockURLProtocol.reset()
        requestCount = 0
        
        config = LicenseSeatConfig(
            apiBaseUrl: "https://api.test.com",
            apiKey: "test-key",
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
    
    func testAuthHeaderPresent() async throws {
        MockURLProtocol.requestHandler = { request in
            let authHeader = request.value(forHTTPHeaderField: "Authorization")
            XCTAssertEqual(authHeader, "Bearer test-key")
            let res = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (res, Data("{}".utf8))
        }
        let _: EmptyResponse = try await apiClient.get(path: "/auth-test")
    }
}

// MARK: - Helpers

private struct TestResponse: Codable, Equatable {
    let message: String
} 