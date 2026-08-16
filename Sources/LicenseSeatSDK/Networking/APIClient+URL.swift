//
//  APIClient+URL.swift
//  LicenseSeatSDK
//
//  Strict endpoint construction for credentialed API requests.
//

import Foundation

extension APIClient {
    /// Production traffic must use TLS. Plain HTTP remains available only for
    /// loopback development servers so local integration tests do not require
    /// a trusted certificate.
    func validatedBaseURL() -> URL? {
        guard config.apiBaseUrl.utf8.count <= Self.maxPathBytes,
              var components = URLComponents(string: config.apiBaseUrl),
              let scheme = components.scheme?.lowercased(),
              let host = components.host?.lowercased(),
              !host.isEmpty,
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil else {
            return nil
        }

        while components.percentEncodedPath.count > 1,
              components.percentEncodedPath.hasSuffix("/") {
            components.percentEncodedPath.removeLast()
        }
        guard let url = components.url else { return nil }

        if scheme == "https" {
            return url
        }

        let loopbackHosts = ["localhost", "127.0.0.1", "::1"]
        return scheme == "http" && loopbackHosts.contains(host) ? url : nil
    }

    /// Construct a URL without ever interpreting a dynamic value as multiple
    /// route components. `URL.appendingPathComponent` preserves embedded `/`
    /// characters, so it cannot safely represent an opaque signing-key ID.
    ///
    /// `queryItems` follows the same rule for the query string: a value is
    /// encoded as exactly one parameter value and can never introduce another
    /// pair. `validatedBaseURL()` rejects a base URL that already carries a
    /// query, so the result is always only what the SDK asked for.
    func endpointURL(
        baseURL: URL,
        pathComponents: [String],
        queryItems: [URLQueryItem] = []
    ) -> URL? {
        guard !pathComponents.isEmpty,
              pathComponents.count <= 32,
              pathComponents.allSatisfy({
                  !$0.isEmpty &&
                      $0.utf8.count <= 512 &&
                      $0.unicodeScalars.allSatisfy { $0.value > 31 && $0.value != 127 }
              }) else {
            return nil
        }

        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/%?#\\")
        let encodedComponents = pathComponents.compactMap { component -> String? in
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
        guard components.percentEncodedPath.utf8.count <= Self.maxPathBytes else { return nil }

        if !queryItems.isEmpty {
            guard let query = encodedQuery(queryItems) else { return nil }
            components.percentEncodedQuery = query
        }
        return components.url
    }

    /// Encode SDK-issued query parameters into a single percent-encoded query
    /// string, or return `nil` when any item falls outside what the SDK is
    /// allowed to send. Rejecting is deliberate: silently dropping an unknown
    /// or malformed filter would issue a broader request than the caller asked
    /// for, and the caller could not tell from the response.
    func encodedQuery(_ queryItems: [URLQueryItem]) -> String? {
        guard queryItems.count <= Self.allowedQueryKeys.count else { return nil }

        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&=+?#/%")
        var usedKeys = Set<String>()
        var encodedPairs: [String] = []

        for item in queryItems {
            guard Self.allowedQueryKeys.contains(item.name),
                  usedKeys.insert(item.name).inserted,
                  let value = item.value,
                  !value.isEmpty,
                  value.utf8.count <= Self.maxQueryValueBytes,
                  value == value.trimmingCharacters(in: .whitespacesAndNewlines),
                  value.unicodeScalars.allSatisfy({ $0.value > 31 && $0.value != 127 }),
                  let encodedValue = value.addingPercentEncoding(
                      withAllowedCharacters: allowed
                  ) else {
                return nil
            }
            encodedPairs.append("\(item.name)=\(encodedValue)")
        }

        let query = encodedPairs.joined(separator: "&")
        guard query.utf8.count <= Self.maxQueryBytes else { return nil }
        return query
    }
}
