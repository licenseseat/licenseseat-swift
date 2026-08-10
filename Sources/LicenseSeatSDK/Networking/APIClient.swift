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
    private static let maxResponseBytes = 2 * 1024 * 1024
    static let maxRequestBytes = 1024 * 1024
    static let maxPathBytes = 2_048
    private static let maxRetries = 10
    private static let maxRetryDelay: TimeInterval = 60
    static let protectedHeaders: Set<String> = [
        "accept", "authorization", "connection", "content-length",
        "content-type", "cookie", "expect", "host", "proxy-authorization",
        "set-cookie", "te", "trailer", "transfer-encoding", "upgrade"
    ]
    static let headerNameCharacters = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789!#$%&'*+-.^_`|~"
    )

    let config: LicenseSeatConfig
    private let session: URLSession
    private let boundedSessionDelegate: BoundedSessionDelegate?
    private let ownsSession: Bool
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
    
    init(
        config: LicenseSeatConfig,
        session: URLSession? = nil,
        ownedSessionConfiguration: URLSessionConfiguration? = nil
    ) {
        self.config = config

        if let session = session {
            self.session = session
            self.boundedSessionDelegate = nil
            self.ownsSession = false
        } else {
            let sourceConfiguration = ownedSessionConfiguration
                ?? URLSessionConfiguration.default
            let configuration = sourceConfiguration.copy() as! URLSessionConfiguration
            configuration.timeoutIntervalForRequest = 30
            configuration.timeoutIntervalForResource = 60
            configuration.httpShouldSetCookies = false
            configuration.httpCookieAcceptPolicy = .never
            configuration.urlCache = nil
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            let delegate = BoundedSessionDelegate()
            self.boundedSessionDelegate = delegate
            self.ownsSession = true
            self.session = URLSession(
                configuration: configuration,
                delegate: delegate,
                delegateQueue: nil
            )
        }
        
        // Configure JSON coding
        self.decoder = JSONDecoder()
        self.decoder.dateDecodingStrategy = .iso8601
    }

    deinit {
        if ownsSession {
            session.invalidateAndCancel()
        }
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
    /// encoded as one path segment. Credentials belong in the request body.
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

        let allHeaders = try requestHeaders(merging: headers)
        let maximumRetries = try validatedMaximumRetries()
        var lastError: Error?

        for attempt in 0...maximumRetries {
            do {
                let request = try makeRequest(
                    url: url,
                    method: method,
                    body: body,
                    headers: allHeaders
                )
                let (data, response) = try await loadBoundedData(for: request)
                let httpResponse = try validatedHTTPResponse(
                    response,
                    data: data,
                    intendedURL: url
                )

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

    private func loadBoundedData(
        for request: URLRequest
    ) async throws -> (Data, URLResponse) {
        if let boundedSessionDelegate {
            return try await boundedSessionDelegate.data(
                for: request,
                using: session,
                maximumBytes: Self.maxResponseBytes
            )
        }

        // An injected session keeps its caller-owned delegate and lifecycle.
        // Acceptance is still bounded below, but callers that inject a session
        // own incremental-delivery and redirect policy during transfer.
        return try await session.data(for: request)
    }

    private func validatedMaximumRetries() throws -> Int {
        guard config.retryDelay.isFinite, config.retryDelay >= 0 else {
            throw APIError.localFailure(
                code: "invalid_retry_configuration",
                message: "Retry delay must be finite and nonnegative"
            )
        }
        return min(max(0, config.maxRetries), Self.maxRetries)
    }

    private func validatedHTTPResponse(
        _ response: URLResponse,
        data: Data,
        intendedURL: URL
    ) throws -> HTTPURLResponse {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.localFailure(
                code: "invalid_response",
                message: "Invalid HTTP response"
            )
        }
        guard httpResponse.url == intendedURL else {
            throw APIError.localFailure(
                code: "unexpected_response_url",
                message: "Response URL did not match the intended endpoint"
            )
        }
        let declaredLength = httpResponse.expectedContentLength
        guard declaredLength < 0 || declaredLength <= Self.maxResponseBytes,
              data.count <= Self.maxResponseBytes else {
            throw APIError.localFailure(
                code: "response_too_large",
                message: "Response exceeds the supported size"
            )
        }
        return httpResponse
    }

    private func decodeSuccess<T: Decodable>(_ data: Data) throws -> T {
        if let emptyResponse = EmptyResponse() as? T {
            return emptyResponse
        }
        guard !data.isEmpty else {
            throw DecodingError.dataCorrupted(
                .init(
                    codingPath: [],
                    debugDescription: "Expected a JSON response body"
                )
            )
        }
        try StrictJSON.validate(data, limits: .api)
        return try decoder.decode(T.self, from: data)
    }

    private func decodeAPIError(data: Data, status: Int) -> APIError {
        guard data.count <= Self.maxResponseBytes else {
            return APIError(
                code: "response_too_large",
                message: "Error response exceeds the supported size",
                status: status
            )
        }
        guard (try? StrictJSON.validate(data, limits: .api)) != nil else {
            return APIError(
                code: nil,
                message: "Request failed",
                status: status
            )
        }
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
        guard config.retryDelay.isFinite, config.retryDelay >= 0 else {
            throw APIError.localFailure(
                code: "invalid_retry_configuration",
                message: "Retry delay must be finite and nonnegative"
            )
        }
        let exponentialDelay = config.retryDelay * pow(2, Double(attempt))
        let delay = min(exponentialDelay, Self.maxRetryDelay)
        log("Retry attempt \(attempt + 1) after \(delay)s for error: \(LogRedaction.describe(error))")
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
    
    func log(_ message: String) {
        guard config.debug else { return }
        print("[LicenseSeat SDK]", message)
    }
}
