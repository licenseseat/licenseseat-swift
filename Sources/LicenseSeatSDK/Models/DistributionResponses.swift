//
//  DistributionResponses.swift
//  LicenseSeatSDK
//
//  Wire-level release and download-token wrappers. Moved verbatim out of
//  License.swift to keep that file within SwiftLint's file_length limit.
//

import Foundation

// MARK: - Release (API Response)

/// Release object
public struct ReleaseResponse: Codable, Equatable, Sendable {
    public let object: String
    public let version: String
    public let channel: String
    public let platform: String
    public let publishedAt: Date
    public let productSlug: String

    enum CodingKeys: String, CodingKey {
        case object
        case version
        case channel
        case platform
        case publishedAt = "published_at"
        case productSlug = "product_slug"
    }
}

// MARK: - Release List (API Response)

/// List response wrapper
public struct ReleaseListResponse: Codable, Equatable, Sendable {
    public let object: String
    public let data: [ReleaseResponse]
    public let hasMore: Bool
    public let nextCursor: String?

    enum CodingKeys: String, CodingKey {
        case object
        case data
        case hasMore = "has_more"
        case nextCursor = "next_cursor"
    }
}

// MARK: - Download Token (API Response)

/// Download token for gated releases
public struct DownloadTokenResponse: Codable, Equatable, Sendable {
    public let object: String
    public let token: String
    public let expiresAt: Date

    enum CodingKeys: String, CodingKey {
        case object
        case token
        case expiresAt = "expires_at"
    }
}
