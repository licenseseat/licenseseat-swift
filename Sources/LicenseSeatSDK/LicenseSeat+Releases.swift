//
//  LicenseSeat+Releases.swift
//  LicenseSeatSDK
//
//  Release discovery and gated-download authorization.
//

import Foundation

/// Channels the distribution API publishes releases on.
private let releaseChannels: Set<String> = ["stable", "beta", "alpha"]

/// Platforms a release may target. `any` means the release applies to every
/// platform, so the server returns it for any platform filter.
private let releasePlatforms: Set<String> = ["macos", "windows", "linux", "any"]
private let anyPlatform = "any"

/// The server bounds `limit` to 100 and treats 0 as unset; rejecting locally
/// keeps a caller from silently receiving the default page instead.
private let releaseLimitRange = 1...100

/// Clock skew tolerated on a server timestamp before it reads as fabricated.
private let releaseClockSkewAllowance: TimeInterval = 5 * 60

/// A download token is minted for minutes, not weeks. Anything claiming a
/// longer life than this did not come from the documented endpoint.
private let maximumDownloadTokenLifetime: TimeInterval = 30 * 24 * 60 * 60
private let downloadTokenLengthRange = 16...(32 * 1024)
private let releaseVersionLengthRange = 1...255

/// Validated release filters plus the query string they serialize to.
private struct ReleaseQuery {
    let productSlug: String
    let channel: String?
    let platform: String?
    let queryItems: [URLQueryItem]
}

public extension LicenseSeat {
    /// Fetch the most recent published release for the configured product.
    ///
    /// This is the version-check half of an update flow: compare the returned
    /// ``Release/version`` against the running build. Hosts using the appcast
    /// rail (Sparkle, Tauri, electron-updater) do not need this call — the
    /// updater polls the feed itself.
    ///
    /// - Parameters:
    ///   - channel: Restrict to `stable`, `beta`, or `alpha`. `nil` means any.
    ///   - platform: Restrict to `macos`, `windows`, `linux`, or `any`. A
    ///     release published for `any` platform matches every filter.
    /// - Returns: The newest published release matching the filters.
    /// - Throws: ``LicenseSeatError/productSlugRequired`` when no product slug
    ///   is configured, ``APIError`` when the request fails or the response
    ///   does not describe the product and filters that were requested.
    func getLatestRelease(
        channel: String? = nil,
        platform: String? = nil
    ) async throws -> Release {
        await waitForInitialization()
        let query = try makeReleaseQuery(channel: channel, platform: platform)

        let release: Release = try await apiClient.get(
            pathComponents: ["products", query.productSlug, "releases", "latest"],
            queryItems: query.queryItems
        )
        try Task.checkCancellation()
        try verifyRelease(release, matching: query)
        return release
    }

    /// List published releases for the configured product, newest first.
    ///
    /// - Parameters:
    ///   - channel: Restrict to `stable`, `beta`, or `alpha`. `nil` means any.
    ///   - platform: Restrict to `macos`, `windows`, `linux`, or `any`.
    ///   - limit: Maximum releases to return, 1...100. `nil` leaves the server
    ///     default (20) in place.
    /// - Returns: The matching releases, newest first.
    /// - Throws: ``LicenseSeatError/productSlugRequired`` when no product slug
    ///   is configured, ``APIError`` when the request fails, the limit is out
    ///   of range, or any item does not match the requested product and filters.
    func listReleases(
        channel: String? = nil,
        platform: String? = nil,
        limit: Int? = nil
    ) async throws -> [Release] {
        await waitForInitialization()
        let query = try makeReleaseQuery(
            channel: channel,
            platform: platform,
            limit: limit
        )

        let list: ReleaseList = try await apiClient.get(
            pathComponents: ["products", query.productSlug, "releases"],
            queryItems: query.queryItems
        )
        try Task.checkCancellation()

        guard list.object == "list" else {
            throw APIError.localFailure(
                code: "invalid_release_response",
                message: "Release list response schema is invalid"
            )
        }
        for release in list.data {
            try verifyRelease(release, matching: query)
        }
        return list.data
    }

    /// Mint a short-lived, signed authorization to download one release.
    ///
    /// Only needed for products whose update feed policy is `licensed` and
    /// whose artifacts are therefore gated. The token is bound to this license
    /// and this release, expires within minutes, and is passed to the download
    /// URL as a `token` query parameter. Do not persist it.
    ///
    /// - Parameters:
    ///   - version: The exact published version to authorize, e.g. `2.1.0`.
    ///   - licenseKey: The license the download is authorized against.
    ///   - platform: Narrow to a platform build when a version publishes more
    ///     than one. `nil` lets the server pick the matching release.
    /// - Returns: The download authorization.
    /// - Throws: ``LicenseSeatError/apiKeyRequired`` when no API key is
    ///   configured, ``LicenseSeatError/productSlugRequired`` when no product
    ///   slug is, or ``APIError`` when the request fails, an argument is
    ///   malformed, or the response is not a usable unexpired token.
    func generateDownloadToken(
        version: String,
        licenseKey: String,
        platform: String? = nil
    ) async throws -> DownloadToken {
        await waitForInitialization()
        guard let apiKey = config.apiKey, !apiKey.isEmpty else {
            throw LicenseSeatError.apiKeyRequired
        }
        guard let productSlug = config.productSlug else {
            throw LicenseSeatError.productSlugRequired
        }
        try validateRequestIdentity(productSlug: productSlug, licenseKey: licenseKey)
        try validateReleaseVersion(version)
        try validateReleasePlatform(platform)

        var body: [String: Any] = ["license_key": licenseKey]
        if let platform, !platform.isEmpty {
            body["platform"] = platform
        }

        // The version is a route component, and the license key is a
        // credential: both stay out of the query string.
        let token: DownloadToken = try await apiClient.post(
            pathComponents: [
                "products", productSlug, "releases", version, "download_token"
            ],
            body: body
        )
        try Task.checkCancellation()
        try verifyDownloadToken(token)
        return token
    }
}

// MARK: - Request Preparation

private extension LicenseSeat {
    func makeReleaseQuery(
        channel: String?,
        platform: String?,
        limit: Int? = nil
    ) throws -> ReleaseQuery {
        guard let productSlug = config.productSlug else {
            throw LicenseSeatError.productSlugRequired
        }
        try validateProductSlug(productSlug)
        try validateReleaseChannel(channel)
        try validateReleasePlatform(platform)
        try validateReleaseLimit(limit)

        var queryItems: [URLQueryItem] = []
        if let channel, !channel.isEmpty {
            queryItems.append(URLQueryItem(name: "channel", value: channel))
        }
        if let platform, !platform.isEmpty {
            queryItems.append(URLQueryItem(name: "platform", value: platform))
        }
        if let limit {
            queryItems.append(URLQueryItem(name: "limit", value: String(limit)))
        }

        return ReleaseQuery(
            productSlug: productSlug,
            channel: channel?.isEmpty == true ? nil : channel,
            platform: platform?.isEmpty == true ? nil : platform,
            queryItems: queryItems
        )
    }

    func validateReleaseChannel(_ channel: String?) throws {
        guard let channel, !channel.isEmpty else { return }
        guard releaseChannels.contains(channel) else {
            throw APIError.localFailure(
                code: "invalid_release_filter",
                message: "Release channel is invalid"
            )
        }
    }

    func validateReleasePlatform(_ platform: String?) throws {
        guard let platform, !platform.isEmpty else { return }
        guard releasePlatforms.contains(platform) else {
            throw APIError.localFailure(
                code: "invalid_release_filter",
                message: "Release platform is invalid"
            )
        }
    }

    func validateReleaseLimit(_ limit: Int?) throws {
        guard let limit else { return }
        guard releaseLimitRange.contains(limit) else {
            throw APIError.localFailure(
                code: "invalid_release_filter",
                message: "Release limit is invalid"
            )
        }
    }

    func validateReleaseVersion(_ version: String) throws {
        guard safeReleaseText(version, in: releaseVersionLengthRange) else {
            throw APIError.localFailure(
                code: "invalid_release_filter",
                message: "Release version is invalid"
            )
        }
    }

    func safeReleaseText(_ value: String, in range: ClosedRange<Int>) -> Bool {
        range.contains(value.utf8.count) &&
            value.unicodeScalars.allSatisfy { $0.value > 31 && $0.value != 127 }
    }
}

// MARK: - Response Verification

private extension LicenseSeat {
    /// A release response is only usable if it describes the product and the
    /// filters that were asked for. Checking locally means a misrouted or
    /// substituted response cannot become the version an updater acts on.
    func verifyRelease(_ release: Release, matching query: ReleaseQuery) throws {
        guard release.productSlug == query.productSlug,
              query.channel.map({ release.channel == $0 }) ?? true,
              // A release published for `any` platform legitimately answers a
              // platform-filtered request: it targets every platform.
              query.platform.map({
                  release.platform == $0 || release.platform == anyPlatform
              }) ?? true else {
            throw APIError.localFailure(
                code: "release_response_mismatch",
                message: "Release response did not match the requested product or filters"
            )
        }

        guard release.object == "release",
              safeReleaseText(release.version, in: releaseVersionLengthRange),
              releaseChannels.contains(release.channel),
              releasePlatforms.contains(release.platform),
              let publishedAt = release.publishedAt,
              publishedAt <= Date().addingTimeInterval(releaseClockSkewAllowance) else {
            throw APIError.localFailure(
                code: "invalid_release_response",
                message: "Release response schema is invalid"
            )
        }
    }

    func verifyDownloadToken(_ token: DownloadToken) throws {
        let now = Date()
        guard token.object == "download_token",
              safeReleaseText(token.token, in: downloadTokenLengthRange),
              let expiresAt = token.expiresAt,
              expiresAt > now,
              expiresAt <= now.addingTimeInterval(maximumDownloadTokenLifetime) else {
            throw APIError.localFailure(
                code: "invalid_download_token_response",
                message: "Download-token response schema is invalid"
            )
        }
    }
}
