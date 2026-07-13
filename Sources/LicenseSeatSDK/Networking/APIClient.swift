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
@MainActor
final class APIClient {
    private let config: LicenseSeatConfig
    private let session: URLSession
    private let decoder: JSONDecoder
    
    /// Callback for network status changes
    var onNetworkStatusChange: ((Bool) -> Void)?
    
    /// Current online status
    private var isOnline = true

    /// Restore the optimistic connectivity baseline after a full SDK reset so
    /// the next transport failure can emit a fresh offline transition.
    func resetNetworkStatus() {
        isOnline = true
    }
    
    init(config: LicenseSeatConfig, session: URLSession? = nil) {
        self.config = config
        
        // Use injected session if provided (useful for unit tests)
        if let session = session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.default
            configuration.timeoutIntervalForRequest = 30
            configuration.timeoutIntervalForResource = 60
            self.session = URLSession(configuration: configuration)
        }
        
        // Configure JSON coding
        self.decoder = JSONDecoder()
        self.decoder.dateDecodingStrategy = .iso8601
    }
    
    // MARK: - Public Methods
    
    /// Make a GET request
    func get<T: Decodable>(
        path: String,
        headers: [String: String] = [:]
    ) async throws -> T {
        try await apiCall(
            pathComponents: path.split(separator: "/").map(String.init),
            method: "GET",
            headers: headers
        )
    }

    /// Make a GET request from discrete route components. Dynamic identifiers
    /// must use this form so reserved characters cannot alter route structure.
    func get<T: Decodable>(
        pathComponents: [String],
        headers: [String: String] = [:]
    ) async throws -> T {
        try await apiCall(pathComponents: pathComponents, method: "GET", headers: headers)
    }
    
    /// Make a POST request from discrete route components. Each component is
    /// encoded as one path segment, including user-provided license keys.
    func post<T: Decodable>(
        pathComponents: [String],
        body: Any? = nil,
        headers: [String: String] = [:]
    ) async throws -> T {
        try await apiCall(
            pathComponents: pathComponents,
            method: "POST",
            body: body,
            headers: headers
        )
    }
    
    // MARK: - Private Methods
    
    private func apiCall<T: Decodable>(
        pathComponents: [String],
        method: String,
        body: Any? = nil,
        headers: [String: String] = [:]
    ) async throws -> T {
        guard let baseURL = validatedBaseURL() else {
            throw APIError(
                code: "invalid_base_url",
                message: "Invalid API base URL",
                status: 0
            )
        }
        guard let url = endpointURL(baseURL: baseURL, pathComponents: pathComponents) else {
            throw APIError(
                code: "invalid_endpoint_path",
                message: "Invalid API endpoint path",
                status: 0
            )
        }

        let allHeaders = requestHeaders(merging: headers)
        let maximumRetries = max(0, config.maxRetries)
        var lastError: Error?

        for attempt in 0...maximumRetries {
            do {
                let request = try makeRequest(
                    url: url,
                    method: method,
                    body: body,
                    headers: allHeaders
                )
                let (data, response) = try await session.data(for: request)
                guard let httpResponse = response as? HTTPURLResponse else {
                    throw APIError(message: "Invalid response", status: 0)
                }

                guard (200...299).contains(httpResponse.statusCode) else {
                    throw decodeAPIError(data: data, status: httpResponse.statusCode)
                }

                markOnlineAfterSuccess()
                return try decodeSuccess(data)
            } catch {
                // Cancellation is a caller decision, not a connectivity change,
                // and must never trigger another HTTP request.
                if Task.isCancelled {
                    throw error
                }

                lastError = error
                markOfflineIfNeeded(for: error)

                guard attempt < maximumRetries, shouldRetryError(error) else {
                    throw error
                }
                try await sleepBeforeRetry(attempt: attempt, error: error)
            }
        }

        throw lastError ?? APIError(message: "Unknown error", status: 0)
    }

    private func requestHeaders(merging headers: [String: String]) -> [String: String] {
        var result = [
            "Content-Type": "application/json",
            "Accept": "application/json"
        ]
        if let apiKey = config.apiKey {
            result["Authorization"] = "Bearer \(apiKey)"
        } else {
            log("[Warning] No API key configured for LicenseSeat SDK. Authenticated endpoints will fail.")
        }
        result.merge(headers) { _, new in new }
        return result
    }

    private func makeRequest(
        url: URL,
        method: String,
        body: Any?,
        headers: [String: String]
    ) throws -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }

        if let body {
            if method == "POST",
               var dictionary = body as? [String: Any],
               config.telemetryEnabled {
                dictionary["telemetry"] = TelemetryPayload.collect().toDictionary()
                request.httpBody = try JSONSerialization.data(withJSONObject: dictionary)
            } else {
                request.httpBody = try JSONSerialization.data(withJSONObject: body)
            }
        }
        return request
    }

    private func decodeSuccess<T: Decodable>(_ data: Data) throws -> T {
        if let emptyResponse = EmptyResponse() as? T {
            return emptyResponse
        }
        return try decoder.decode(T.self, from: data)
    }

    private func decodeAPIError(data: Data, status: Int) -> APIError {
        let responseData = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        return APIError(from: responseData, status: status)
    }

    private func markOnlineAfterSuccess() {
        guard !isOnline else { return }
        isOnline = true
        onNetworkStatusChange?(true)
    }

    private func markOfflineIfNeeded(for error: Error) {
        guard isOnline, isNetworkError(error) else { return }
        isOnline = false
        onNetworkStatusChange?(false)
    }

    private func sleepBeforeRetry(attempt: Int, error: Error) async throws {
        let baseDelay = config.retryDelay.isFinite ? max(0, config.retryDelay) : 0
        let exponentialDelay = baseDelay * pow(2, Double(attempt))
        let maximumSleepSeconds = Double(UInt64.max / 1_000_000_000)
        let delay = min(exponentialDelay, maximumSleepSeconds)
        log("Retry attempt \(attempt + 1) after \(delay)s for error: \(error)")
        guard delay.isFinite, delay > 0 else { return }
        try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
    }

    private func isNetworkError(_ error: Error) -> Bool {
        if let urlError = error as? URLError {
            return urlError.code != .cancelled
        }
        
        if let apiError = error as? APIError {
            return apiError.isNetworkError
        }
        
        return false
    }

    /// Production traffic must use TLS. Plain HTTP remains available only for
    /// loopback development servers so local integration tests do not require
    /// a trusted certificate.
    private func validatedBaseURL() -> URL? {
        guard let url = URL(string: config.apiBaseUrl),
              let scheme = url.scheme?.lowercased(),
              let host = url.host?.lowercased(),
              url.user == nil,
              url.password == nil,
              url.query == nil,
              url.fragment == nil else {
            return nil
        }

        if scheme == "https" {
            return url
        }

        let loopbackHosts = ["localhost", "127.0.0.1", "::1"]
        return scheme == "http" && loopbackHosts.contains(host) ? url : nil
    }

    /// Construct a URL without ever interpreting a dynamic value as multiple
    /// route components. `URL.appendingPathComponent` preserves embedded `/`
    /// characters, so it cannot safely represent an opaque license/key ID.
    private func endpointURL(baseURL: URL, pathComponents: [String]) -> URL? {
        guard !pathComponents.isEmpty,
              pathComponents.allSatisfy({ !$0.isEmpty }) else {
            return nil
        }

        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/%?#\\")
        let encodedComponents = pathComponents.compactMap { component -> String? in
            // Dot-only segments can be normalized by clients or proxies even
            // though they are legitimate opaque strings, so force encoding.
            if component == "." { return "%2E" }
            if component == ".." { return "%2E%2E" }
            return component.addingPercentEncoding(withAllowedCharacters: allowed)
        }
        guard encodedComponents.count == pathComponents.count,
              var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            return nil
        }

        var basePath = components.percentEncodedPath
        while basePath.count > 1, basePath.hasSuffix("/") {
            basePath.removeLast()
        }
        if basePath == "/" {
            basePath = ""
        }
        components.percentEncodedPath = "\(basePath)/\(encodedComponents.joined(separator: "/"))"
        return components.url
    }
    
    private func shouldRetryError(_ error: Error) -> Bool {
        // Network errors from URLSession
        if let urlError = error as? URLError {
            return urlError.code != .cancelled
        }

        // API errors - delegate to the error's own retry logic
        if let apiError = error as? APIError {
            return apiError.isRetryable
        }

        return false
    }
    
    private func log(_ message: String) {
        guard config.debug else { return }
        print("[LicenseSeat SDK]", message)
    }
}
