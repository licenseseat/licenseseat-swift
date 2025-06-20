import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest

/// A URLProtocol subclass that allows unit tests to stub network responses
final class MockURLProtocol: URLProtocol {
    /// Request handler provided per-test. Throw to simulate networking errors.
    static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?
    
    /// Helper to reset global state between tests
    static func reset() {
        requestHandler = nil
    }
    
    override class func canInit(with request: URLRequest) -> Bool {
        // Intercept every request
        true
    }
    
    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }
    
    override func startLoading() {
        guard let handler = MockURLProtocol.requestHandler else {
            // If no handler is provided, respond with 200 and empty JSON to avoid crashing tests
            let emptyData = try! JSONSerialization.data(withJSONObject: [:])
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: emptyData)
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }
    
    override func stopLoading() {}
} 