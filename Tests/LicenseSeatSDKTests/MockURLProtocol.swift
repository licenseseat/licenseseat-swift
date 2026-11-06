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
    
    nonisolated(unsafe) private static var asyncStorage = false

    /// Run handlers off URLSession's protocol queue (Darwin only), so a
    /// handler that blocks does not hold back other requests of the same
    /// session. Needed to interleave two in-flight requests in race tests.
    static var deliversAsynchronously: Bool {
        get {
            handlerLock.lock()
            defer { handlerLock.unlock() }
            return asyncStorage
        }
        set {
            handlerLock.lock()
            asyncStorage = newValue
            handlerLock.unlock()
        }
    }

    /// Helper to reset global state between tests
    static func reset() {
        requestHandler = nil
        deliversAsynchronously = false
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
        #if canImport(Darwin)
        if Self.deliversAsynchronously {
            // Call the handler elsewhere, but talk to the client on the thread
            // URLSession started us on, as URLProtocol requires.
            nonisolated(unsafe) let clientThread = Thread.current
            nonisolated(unsafe) let protocolInstance = self
            nonisolated(unsafe) let unsafeHandler = handler
            let request = self.request
            DispatchQueue.global().async {
                let outcome = OutcomeBox(Result { try unsafeHandler(request) })
                protocolInstance.perform(
                    #selector(MockURLProtocol.deliver(_:)),
                    on: clientThread,
                    with: outcome,
                    waitUntilDone: false
                )
            }
            return
        }
        #endif
        deliver(OutcomeBox(Result { try handler(request) }))
    }

    #if canImport(Darwin)
    @objc private func deliver(_ box: OutcomeBox) {
        deliverOutcome(box)
    }
    #else
    private func deliver(_ box: OutcomeBox) {
        deliverOutcome(box)
    }
    #endif

    private func deliverOutcome(_ box: OutcomeBox) {
        switch box.outcome {
        case .success(let (response, data)):
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        case .failure(let error):
            client?.urlProtocol(self, didFailWithError: error)
        }
    }
    
    override func stopLoading() {}
}

/// Carries a handler outcome across `perform(_:on:with:waitUntilDone:)`.
final class OutcomeBox: NSObject, @unchecked Sendable {
    let outcome: Result<(HTTPURLResponse, Data), Error>

    init(_ outcome: Result<(HTTPURLResponse, Data), Error>) {
        self.outcome = outcome
    }
}
