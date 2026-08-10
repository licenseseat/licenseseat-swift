//
//  APIClient+Request.swift
//  LicenseSeatSDK
//
//  Header invariants and bounded JSON request construction.
//

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

extension APIClient {
    func requestHeaders(merging headers: [String: String]) throws -> [String: String] {
        var result = [
            "Content-Type": "application/json",
            "Accept": "application/json"
        ]
        if let apiKey = config.apiKey {
            guard apiKey.utf8.count <= 4_096,
                  !apiKey.isEmpty,
                  apiKey.unicodeScalars.allSatisfy({
                      $0.value > 32 && $0.value < 127
                  }) else {
                throw APIError.localFailure(
                    code: "invalid_headers",
                    message: "API key contains invalid characters or exceeds SDK limits"
                )
            }
            result["Authorization"] = "Bearer \(apiKey)"
        } else {
            log("[Warning] No API key configured for LicenseSeat SDK. Authenticated endpoints will fail.")
        }
        for (key, value) in headers {
            guard validHeaderName(key), validHeaderValue(value) else {
                throw APIError.localFailure(
                    code: "invalid_headers",
                    message: "Request headers contain invalid characters or exceed SDK limits"
                )
            }
            guard !Self.protectedHeaders.contains(key.lowercased()) else { continue }
            result[key] = value
        }
        return result
    }

    private func validHeaderName(_ name: String) -> Bool {
        !name.isEmpty &&
            name.utf8.count <= 128 &&
            name.unicodeScalars.allSatisfy {
                Self.headerNameCharacters.contains($0)
            }
    }

    private func validHeaderValue(_ value: String) -> Bool {
        value.utf8.count <= 8_192 &&
            value == value.trimmingCharacters(in: .whitespacesAndNewlines) &&
            value.unicodeScalars.allSatisfy { $0.value >= 32 && $0.value < 127 }
    }

    func makeRequest(
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
        guard (request.httpBody?.count ?? 0) <= Self.maxRequestBytes else {
            throw APIError.localFailure(
                code: "request_too_large",
                message: "Request exceeds the supported size"
            )
        }
        return request
    }
}
