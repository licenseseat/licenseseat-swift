//
//  DownloadToken.swift
//  LicenseSeatSDK
//
//  Short-lived download authorization returned by the distribution API.
//

import Foundation

/// A time-limited, signed authorization to download one specific release.
///
/// Response format: `{"object": "download_token", "token": "...",
/// "expires_at": "..."}`.
///
/// The token is a bearer credential bound to the license and release it was
/// minted for. Treat it like one: pass it to the download URL, do not persist
/// it, and let it expire rather than caching it for reuse.
public struct DownloadToken: Codable, Equatable, Sendable {
    /// Object type (always `download_token`).
    public let object: String

    /// The signed authorization token.
    public let token: String

    /// When the token stops being accepted. Typically a few minutes out.
    public let expiresAt: Date?

    enum CodingKeys: String, CodingKey {
        case object
        case token
        case expiresAt = "expires_at"
    }

    public init(object: String, token: String, expiresAt: Date? = nil) {
        self.object = object
        self.token = token
        self.expiresAt = expiresAt
    }
}

// MARK: - Redacted Description

/// The synthesized description would print the bearer token into any log line
/// that interpolates the value, so both description forms redact it. The token
/// remains available through ``DownloadToken/token`` for callers that need it.
extension DownloadToken: CustomStringConvertible, CustomDebugStringConvertible {
    public var description: String {
        "DownloadToken(object: \(object), token: <redacted>, expiresAt: "
            + String(describing: expiresAt) + ")"
    }

    public var debugDescription: String { description }
}
