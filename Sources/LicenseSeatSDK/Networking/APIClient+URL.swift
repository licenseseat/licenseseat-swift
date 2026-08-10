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
    func endpointURL(baseURL: URL, pathComponents: [String]) -> URL? {
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
        return components.url
    }
}
