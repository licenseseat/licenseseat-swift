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

/// API client with retry logic and exponential backoff
final class APIClient {
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
            self.session = URLSession(configuration: configuration)
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
        let url = URL(string: config.apiBaseUrl + path)!
        var lastError: Error?
        
        // Prepare headers
        var allHeaders = [
            "Content-Type": "application/json",
            "Accept": "application/json"
        ]
        
        if let apiKey = config.apiKey {
            allHeaders["Authorization"] = "Bearer \(apiKey)"
        } else {
            log("[Warning] No API key configured for LicenseSeat SDK. Authenticated endpoints will fail.")
        }
        
        // Merge custom headers
        allHeaders.merge(headers) { _, new in new }
        
        // Retry loop
        for attempt in 0...config.maxRetries {
            do {
                var request = URLRequest(url: url)
                request.httpMethod = method
                
                // Set headers
                for (key, value) in allHeaders {
                    request.setValue(value, forHTTPHeaderField: key)
                }
                
                // Set body
                if let bodyData = bodyData {
                    request.httpBody = bodyData
                } else if let body = body {
                    request.httpBody = try JSONSerialization.data(withJSONObject: body)
                }
                
                // Make request
                let (data, response) = try await session.data(for: request)
                
                guard let httpResponse = response as? HTTPURLResponse else {
                    throw APIError(message: "Invalid response", status: 0, reasonCode: nil)
                }
                
                // Check status code
                if httpResponse.statusCode >= 200 && httpResponse.statusCode < 300 {
                    // Success - update online status if needed
                    if !isOnline {
                        isOnline = true
                        onNetworkStatusChange?(true)
                    }
                    
                    // Decode response
                    if T.self == EmptyResponse.self {
                        return EmptyResponse() as! T
                    }
                    
                    return try decoder.decode(T.self, from: data)
                } else {
                    // Error response
                    var errorData: [String: Any]?
                    if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                        errorData = json
                    }
                    
                    let error = errorData?["error"] as? String ?? "Request failed"
                    throw APIError(message: error, status: httpResponse.statusCode, data: errorData)
                }
                
            } catch {
                lastError = error
                
                // Check if network failure
                if isNetworkError(error) && isOnline {
                    isOnline = false
                    onNetworkStatusChange?(false)
                }
                
                // Determine if we should retry
                let shouldRetry = attempt < config.maxRetries && shouldRetryError(error)
                
                if shouldRetry {
                    let delay = config.retryDelay * pow(2, Double(attempt))
                    log("Retry attempt \(attempt + 1) after \(delay)s for error: \(error)")
                    try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                } else {
                    throw error
                }
            }
        }
        
        throw lastError ?? APIError(message: "Unknown error", status: 0, reasonCode: nil)
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
    
    private func log(_ message: String) {
        guard config.debug else { return }
        print("[LicenseSeat SDK]", message)
    }
} 