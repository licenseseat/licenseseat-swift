import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest

/// A URLProtocol subclass that allows unit tests to stub network responses
final class MockURLProtocol: URLProtocol {
    private static let handlerLock = NSLock()
    nonisolated(unsafe) private static var handlerStorage: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    /// Request handler provided per-test. Throw to simulate networking errors.
    static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))? {
        get {
            handlerLock.lock()
            defer { handlerLock.unlock() }
            return handlerStorage
        }
        set {
            handlerLock.lock()
            handlerStorage = newValue
            handlerLock.unlock()
        }
    }
    
    /// Helper to reset global state between tests
    static func reset() {
        requestHandler = nil
    }

    /// URLSession may present a request body to URLProtocol as a stream even
    /// when the caller assigned URLRequest.httpBody. Tests inspect the exact
    /// credential-bearing JSON without assuming either representation.
    static func bodyData(for request: URLRequest) -> Data? {
        if let body = request.httpBody {
            return body
        }
        guard let stream = request.httpBodyStream else { return nil }

        stream.open()
        defer { stream.close() }
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count >= 0 else { return nil }
            if count == 0 { break }
            result.append(contentsOf: buffer.prefix(count))
            guard result.count <= 1024 * 1024 else { return nil }
        }
        return result
    }

    static func jsonBody(for request: URLRequest) -> [String: Any] {
        guard let data = bodyData(for: request),
              let object = try? JSONSerialization.jsonObject(with: data),
              let body = object as? [String: Any] else {
            return [:]
        }
        return body
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
