//
//  Release.swift
//  LicenseSeatSDK
//
//  Published release metadata returned by the distribution API.
//

import Foundation

/// A published release of the configured product.
///
/// Response format: `{"object": "release", "version": "2.1.0", "channel":
/// "stable", "platform": "macos", "published_at": "...", "product_slug": "..."}`.
///
/// Only fields the API documents as serialized are decoded; anything else the
/// server adds later is ignored rather than treated as a decoding failure.
public struct Release: Codable, Equatable, Sendable {
    /// Object type (always `release`).
    public let object: String

    /// Release version string, as published (for example `2.1.0`).
    public let version: String

    /// Release channel: `stable`, `beta`, or `alpha`.
    public let channel: String

    /// Target platform: `macos`, `windows`, `linux`, or `any`.
    ///
    /// A release published as `any` is returned for every platform filter,
    /// because it applies to all of them.
    public let platform: String

    /// Slug of the product the release belongs to.
    public let productSlug: String

    /// When the release was published.
    public let publishedAt: Date?

    enum CodingKeys: String, CodingKey {
        case object
        case version
        case channel
        case platform
        case productSlug = "product_slug"
        case publishedAt = "published_at"
    }

    public init(
        object: String,
        version: String,
        channel: String,
        platform: String,
        productSlug: String,
        publishedAt: Date? = nil
    ) {
        self.object = object
        self.version = version
        self.channel = channel
        self.platform = platform
        self.productSlug = productSlug
        self.publishedAt = publishedAt
    }
}

// MARK: - Release List Envelope

/// The paginated envelope the API wraps release lists in:
/// `{"object": "list", "data": [...], "has_more": false, "next_cursor": null}`.
///
/// Internal because the public surface returns the releases themselves; the
/// envelope exists to be validated, not handed to callers.
struct ReleaseList: Codable, Equatable, Sendable {
    let object: String
    let data: [Release]
    let hasMore: Bool
    let nextCursor: String?

    enum CodingKeys: String, CodingKey {
        case object
        case data
        case hasMore = "has_more"
        case nextCursor = "next_cursor"
    }

    init(
        object: String,
        data: [Release],
        hasMore: Bool = false,
        nextCursor: String? = nil
    ) {
        self.object = object
        self.data = data
        self.hasMore = hasMore
        self.nextCursor = nextCursor
    }

    /// A bare array is accepted alongside the envelope so a deployment that
    /// predates the list wrapper still decodes. The absent envelope is treated
    /// as a single complete page, which is what such a response means.
    init(from decoder: Decoder) throws {
        if let container = try? decoder.container(keyedBy: CodingKeys.self),
           container.contains(.data) {
            self.object = try container.decode(String.self, forKey: .object)
            self.data = try container.decode([Release].self, forKey: .data)
            self.hasMore = try container.decodeIfPresent(Bool.self, forKey: .hasMore) ?? false
            self.nextCursor = try container.decodeIfPresent(String.self, forKey: .nextCursor)
            return
        }

        let container = try decoder.singleValueContainer()
        self.object = "list"
        self.data = try container.decode([Release].self)
        self.hasMore = false
        self.nextCursor = nil
    }
}
