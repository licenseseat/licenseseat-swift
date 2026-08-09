//
//  APIClient.swift
//  LicenseSeatSDK
//
//  Created by LicenseSeat on 2025.
//  Copyright © 2025 LicenseSeat. All rights reserved.
//

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Empty response placeholder for endpoints that return no body
struct EmptyResponse: Decodable {}

/// API client with retry logic and exponential backoff
final class APIClient {
    private static let maxResponseBytes = 2 * 1024 * 1024
    private static let maxRequestBytes = 1024 * 1024
    private static let maxRetries = 10
    private static let maxRetryDelay: TimeInterval = 60

    private let config: LicenseSeatConfig
    private let session: URLSession
    private let decoder: JSONDecoder
    private let encoder: JSONEncoder
    
    /// Callback for network status changes
    var onNetworkStatusChange: ((Bool) -> Void)?
    
    /// Current online status
    private var isOnline = true
    
    init(config: LicenseSeatConfig, session: URLSession? = nil) {
        self.config = config
        
        // Use injected session if provided (useful for unit tests)
        if let session = session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.default
            configuration.timeoutIntervalForRequest = 30
            configuration.timeoutIntervalForResource = 60
            configuration.httpShouldSetCookies = false
            configuration.httpCookieAcceptPolicy = .never
            configuration.urlCache = nil
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            self.session = URLSession(
                configuration: configuration,
                delegate: RedirectRejectingDelegate.shared,
                delegateQueue: nil
            )
        }
        
        // Configure JSON coding
        self.decoder = JSONDecoder()
        self.decoder.dateDecodingStrategy = .iso8601
        
        self.encoder = JSONEncoder()
        self.encoder.dateEncodingStrategy = .iso8601
    }
    
    // MARK: - Public Methods
    
    /// Make a GET request
    func get<T: Decodable>(
        path: String,
        headers: [String: String] = [:]
    ) async throws -> T {
        try await apiCall(path: path, method: "GET", headers: headers)
    }
    
    /// Make a POST request
    func post<T: Decodable>(
        path: String,
        body: Any? = nil,
        headers: [String: String] = [:]
    ) async throws -> T {
        try await apiCall(path: path, method: "POST", body: body, headers: headers)
    }
    
    /// Make a POST request with Encodable body
    func post<B: Encodable, T: Decodable>(
        path: String,
        body: B,
        headers: [String: String] = [:]
    ) async throws -> T {
        let bodyData = try encoder.encode(body)
        return try await apiCall(path: path, method: "POST", bodyData: bodyData, headers: headers)
    }
    
    // MARK: - Private Methods
    
    private func apiCall<T: Decodable>(
        path: String,
        method: String,
        body: Any? = nil,
        bodyData: Data? = nil,
        headers: [String: String] = [:]
    ) async throws -> T {
        let url = try makeURL(path: path)
        let allHeaders = requestHeaders(customHeaders: headers)
        let retryCount = min(max(config.maxRetries, 0), Self.maxRetries)
        guard config.retryDelay.isFinite, config.retryDelay >= 0 else {
            throw LicenseSeatError.invalidConfiguration
        }
        var lastError: Error?

        // Retry loop
        for attempt in 0...retryCount {
            do {
                let request = try makeRequest(
                    url: url,
                    method: method,
                    body: body,
                    bodyData: bodyData,
                    headers: allHeaders
                )
                return try await send(request, expectedURL: url)
            } catch {
                lastError = error
                markOfflineIfNeeded(for: error)

                guard attempt < retryCount, shouldRetryError(error) else {
                    throw error
                }
                let delay = try retryDelay(for: attempt)
                log("Retry attempt \(attempt + 1) after \(delay)s (\(String(describing: type(of: error))))")
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
        }

        throw lastError ?? APIError(message: "Unknown error", status: 0)
    }

    private func requestHeaders(customHeaders: [String: String]) -> [String: String] {
        var headers = [
            "Content-Type": "application/json",
            "Accept": "application/json"
        ]
        if let apiKey = config.apiKey {
            headers["Authorization"] = "Bearer \(apiKey)"
        } else {
            log("[Warning] No API key configured for LicenseSeat SDK. Authenticated endpoints will fail.")
        }

        // Never allow callers to replace the SDK's authentication or content
        // negotiation boundary.
        let protectedHeaders = ["authorization", "content-type", "accept"]
        for (key, value) in customHeaders where !protectedHeaders.contains(key.lowercased()) {
            headers[key] = value
        }
        return headers
    }

    private func makeRequest(
        url: URL,
        method: String,
        body: Any?,
        bodyData: Data?,
        headers: [String: String]
    ) throws -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }

        if let bodyData {
            request.httpBody = bodyData
        } else if let body {
            if method == "POST", var bodyDictionary = body as? [String: Any], config.telemetryEnabled {
                bodyDictionary["telemetry"] = TelemetryPayload.collect().toDictionary()
                request.httpBody = try JSONSerialization.data(withJSONObject: bodyDictionary)
            } else {
                request.httpBody = try JSONSerialization.data(withJSONObject: body)
            }
        }

        guard (request.httpBody?.count ?? 0) <= Self.maxRequestBytes else {
            throw LicenseSeatError.invalidConfiguration
        }
        return request
    }

    private func send<T: Decodable>(_ request: URLRequest, expectedURL: URL) async throws -> T {
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError(message: "Invalid response", status: 0)
        }
        guard httpResponse.url == expectedURL else {
            throw LicenseSeatError.invalidConfiguration
        }
        guard data.count <= Self.maxResponseBytes else {
            throw APIError(message: "Response exceeds the supported size", status: 0)
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw APIError(from: errorPayload(from: data), status: httpResponse.statusCode)
        }

        markOnlineIfNeeded()
        if T.self == EmptyResponse.self {
            return EmptyResponse() as! T
        }
        return try decoder.decode(T.self, from: data)
    }

    private func errorPayload(from data: Data) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    private func markOnlineIfNeeded() {
        guard !isOnline else { return }
        isOnline = true
        onNetworkStatusChange?(true)
    }

    private func markOfflineIfNeeded(for error: Error) {
        guard isOnline, isNetworkError(error) else { return }
        isOnline = false
        onNetworkStatusChange?(false)
    }

    private func retryDelay(for attempt: Int) throws -> TimeInterval {
        let delay = min(config.retryDelay * pow(2, Double(attempt)), Self.maxRetryDelay)
        guard delay.isFinite, delay >= 0 else {
            throw LicenseSeatError.invalidConfiguration
        }
        return delay
    }
    
    private func isNetworkError(_ error: Error) -> Bool {
        if error is URLError {
            return true
        }
        
        if let apiError = error as? APIError, apiError.status == 0 {
            return true
        }
        
        return false
    }
    
    private func shouldRetryError(_ error: Error) -> Bool {
        // Network errors from URLSession
        if error is URLError {
            return true
        }

        // API errors - delegate to the error's own retry logic
        if let apiError = error as? APIError {
            return apiError.isRetryable
        }

        return false
    }

    private func makeURL(path: String) throws -> URL {
        guard path.utf8.count <= 2_048,
              path.hasPrefix("/"),
              !path.contains("\\"),
              !path.contains("?"),
              !path.contains("#"),
              var components = URLComponents(string: config.apiBaseUrl),
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil,
              let scheme = components.scheme?.lowercased(),
              let host = components.host?.lowercased(),
              !host.isEmpty else {
            throw LicenseSeatError.invalidConfiguration
        }

        let isLoopback = host == "localhost" || host == "127.0.0.1" || host == "::1"
        guard scheme == "https" || (scheme == "http" && isLoopback) else {
            throw LicenseSeatError.invalidConfiguration
        }

        let basePath = components.percentEncodedPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let requestPath = path.drop(while: { $0 == "/" })
        components.percentEncodedPath = "/" + [basePath, String(requestPath)].filter { !$0.isEmpty }.joined(separator: "/")

        guard let url = components.url else {
            throw LicenseSeatError.invalidConfiguration
        }
        return url
    }
    
    private func log(_ message: String) {
        guard config.debug else { return }
        print("[LicenseSeat SDK]", message)
    }
}

private final class RedirectRejectingDelegate: NSObject, URLSessionTaskDelegate {
    static let shared = RedirectRejectingDelegate()

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}
