//
//  License.swift
//  LicenseSeatSDK
//
//  Created by LicenseSeat on 2025.
//  Copyright © 2025 LicenseSeat. All rights reserved.
//

import Foundation

// Wire-level child objects are intentionally namespaced under their response.
// swiftlint:disable nesting

// MARK: - Product

/// Product information included in license responses
public struct Product: Codable, Equatable, Sendable {
    public let slug: String
    public let name: String
}

// MARK: - Entitlement

/// Represents an entitlement (feature flag) attached to a license
public struct Entitlement: Codable, Equatable, Sendable {
    /// Unique key for the entitlement
    public let key: String

    /// Expiration date (if applicable)
    public let expiresAt: Date?

    /// Exclusive core-semver version ceiling (server-enforced on the
    /// `updates` entitlement since LicenseSeat API 2026-08-19): the license
    /// covers app versions strictly below this. `nil` means unbounded, and
    /// servers older than the field simply never send it.
    public let belowVersion: String?

    /// Additional metadata
    public let metadata: [String: AnyCodable]?

    enum CodingKeys: String, CodingKey {
        case key
        case expiresAt = "expires_at"
        case belowVersion = "below_version"
        case metadata
    }

    public init(key: String, expiresAt: Date? = nil, belowVersion: String? = nil, metadata: [String: AnyCodable]? = nil) {
        self.key = key
        self.expiresAt = expiresAt
        self.belowVersion = belowVersion
        self.metadata = metadata
    }

    /// Whether this entitlement's version ceiling covers the given app
    /// version — the client-side half of the server's version gate, for
    /// apps that want to enforce locally as well (belt-and-suspenders when
    /// the server was never told the app's version).
    ///
    /// No ceiling covers everything. The comparison matches the server's
    /// rule exactly: **exclusive**, on **core** versions (`"3.0"` counts as
    /// `3.0.0`; a prerelease OF the ceiling is not below it), failing
    /// **open** on unparseable strings — local gating is a second line of
    /// defense and must never brick an app; the server stays authoritative.
    public func covers(version: String) -> Bool {
        Self.versionCovered(version, byCeiling: belowVersion)
    }

    /// The pure comparison behind ``covers(version:)``, for callers that
    /// hold the ceiling as a bare string.
    public static func versionCovered(_ version: String, byCeiling ceiling: String?) -> Bool {
        guard let ceiling else { return true }
        guard let lhs = coreComponents(version), let rhs = coreComponents(ceiling) else {
            return true
        }
        for (l, r) in zip(lhs, rhs) where l != r { return l < r }
        return false
    }

    private static func coreComponents(_ version: String) -> [Int]? {
        let trimmed = version.trimmingCharacters(in: .whitespaces)
        guard let core = trimmed.split(separator: "-", maxSplits: 1).first?
            .split(separator: "+", maxSplits: 1).first else { return nil }
        let parts = core.split(separator: ".").map { Int($0) }
        guard (1...3).contains(parts.count), parts.allSatisfy({ $0 != nil }) else { return nil }
        var numbers = parts.compactMap { $0 }
        while numbers.count < 3 { numbers.append(0) }
        return numbers
    }
}

// MARK: - License (API Response)

/// License object as returned by the API
/// Response format: `{"object": "license", "key": "...", ...}`
public struct LicenseResponse: Codable, Equatable, Sendable {
    public let object: String
    public let key: String
    public let status: String
    public let startsAt: Date?
    public let expiresAt: Date?
    public let mode: String
    public let planKey: String
    public let seatLimit: Int?
    public let activeSeats: Int
    public let activeEntitlements: [Entitlement]
    public let metadata: [String: AnyCodable]?
    public let product: Product

    enum CodingKeys: String, CodingKey {
        case object
        case key
        case status
        case startsAt = "starts_at"
        case expiresAt = "expires_at"
        case mode
        case planKey = "plan_key"
        case seatLimit = "seat_limit"
        case activeSeats = "active_seats"
        case activeEntitlements = "active_entitlements"
        case metadata
        case product
    }
}

// MARK: - Activation (API Response)

/// Activation object as returned by the API
/// Response format: `{"object": "activation", "id": "uuid", "device_id": "...", ...}`
public struct ActivationResponse: Codable, Equatable, Sendable {
    public let object: String
    public let id: String
    public let deviceId: String
    public let deviceName: String?
    public let licenseKey: String
    public let activatedAt: Date
    public let deactivatedAt: Date?
    public let ipAddress: String?
    public let metadata: [String: AnyCodable]?
    public let license: LicenseResponse

    enum CodingKeys: String, CodingKey {
        case object
        case id
        case fingerprint
        case deviceId = "device_id"
        case deviceFingerprint = "device_fingerprint"
        case deviceName = "device_name"
        case licenseKey = "license_key"
        case activatedAt = "activated_at"
        case deactivatedAt = "deactivated_at"
        case ipAddress = "ip_address"
        case metadata
        case license
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        object = try container.decode(String.self, forKey: .object)
        id = try container.decodeStringOrInteger(forKey: .id)
        deviceId = try container.decodeFirstPresentString(
            forKeys: [.fingerprint, .deviceId, .deviceFingerprint]
        )
        deviceName = try container.decodeIfPresent(String.self, forKey: .deviceName)
        licenseKey = try container.decode(String.self, forKey: .licenseKey)
        activatedAt = try container.decode(Date.self, forKey: .activatedAt)
        deactivatedAt = try container.decodeIfPresent(Date.self, forKey: .deactivatedAt)
        ipAddress = try container.decodeIfPresent(String.self, forKey: .ipAddress)
        metadata = try container.decodeIfPresent([String: AnyCodable].self, forKey: .metadata)
        license = try container.decode(LicenseResponse.self, forKey: .license)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(object, forKey: .object)
        try container.encode(id, forKey: .id)
        try container.encode(deviceId, forKey: .fingerprint)
        try container.encodeIfPresent(deviceName, forKey: .deviceName)
        try container.encode(licenseKey, forKey: .licenseKey)
        try container.encode(activatedAt, forKey: .activatedAt)
        try container.encodeIfPresent(deactivatedAt, forKey: .deactivatedAt)
        try container.encodeIfPresent(ipAddress, forKey: .ipAddress)
        try container.encodeIfPresent(metadata, forKey: .metadata)
        try container.encode(license, forKey: .license)
    }
}

// MARK: - Deactivation (API Response)

/// Deactivation object as returned by the API
/// Response format: `{"object": "deactivation", "activation_id": "uuid", "deactivated_at": "..."}`
public struct DeactivationResponse: Codable, Equatable, Sendable {
    public let object: String
    public let activationId: String
    public let deactivatedAt: Date

    enum CodingKeys: String, CodingKey {
        case object
        case activationId = "activation_id"
        case deactivatedAt = "deactivated_at"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        object = try container.decode(String.self, forKey: .object)
        activationId = try container.decodeStringOrInteger(forKey: .activationId)
        deactivatedAt = try container.decode(Date.self, forKey: .deactivatedAt)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(object, forKey: .object)
        try container.encode(activationId, forKey: .activationId)
        try container.encode(deactivatedAt, forKey: .deactivatedAt)
    }
}

// MARK: - Validation Warning

/// Warning returned during license validation
public struct ValidationWarning: Codable, Equatable, Sendable {
    public let code: String
    public let message: String
}

// MARK: - Validation Result (API Response)

/// Validation result as returned by the API
/// Response format: `{"object": "validation_result", "valid": true, "license": {...}, ...}`
public struct ValidationResponse: Codable, Equatable, Sendable {
    public let object: String
    public let valid: Bool
    public let code: String?
    public let message: String?
    public let warnings: [ValidationWarning]?
    public let license: LicenseResponse
    public let activation: ActivationResponseNested?

    /// Nested activation without full license (to avoid circular reference)
    public struct ActivationResponseNested: Codable, Equatable, Sendable {
        public let id: String
        public let deviceId: String
        public let deviceName: String?
        public let licenseKey: String
        public let activatedAt: Date
        public let deactivatedAt: Date?
        public let ipAddress: String?
        public let metadata: [String: AnyCodable]?

        enum CodingKeys: String, CodingKey {
            case id
            case fingerprint
            case deviceId = "device_id"
            case deviceFingerprint = "device_fingerprint"
            case deviceName = "device_name"
            case licenseKey = "license_key"
            case activatedAt = "activated_at"
            case deactivatedAt = "deactivated_at"
            case ipAddress = "ip_address"
            case metadata
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decodeStringOrInteger(forKey: .id)
            deviceId = try container.decodeFirstPresentString(
                forKeys: [.fingerprint, .deviceId, .deviceFingerprint]
            )
            deviceName = try container.decodeIfPresent(String.self, forKey: .deviceName)
            licenseKey = try container.decode(String.self, forKey: .licenseKey)
            activatedAt = try container.decode(Date.self, forKey: .activatedAt)
            deactivatedAt = try container.decodeIfPresent(Date.self, forKey: .deactivatedAt)
            ipAddress = try container.decodeIfPresent(String.self, forKey: .ipAddress)
            metadata = try container.decodeIfPresent([String: AnyCodable].self, forKey: .metadata)
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(id, forKey: .id)
            try container.encode(deviceId, forKey: .fingerprint)
            try container.encodeIfPresent(deviceName, forKey: .deviceName)
            try container.encode(licenseKey, forKey: .licenseKey)
            try container.encode(activatedAt, forKey: .activatedAt)
            try container.encodeIfPresent(deactivatedAt, forKey: .deactivatedAt)
            try container.encodeIfPresent(ipAddress, forKey: .ipAddress)
            try container.encodeIfPresent(metadata, forKey: .metadata)
        }
    }
}

// MARK: - Health (API Response)

/// Health check response
/// Response format: `{"object": "health", "status": "healthy", ...}`
public struct HealthResponse: Codable, Equatable, Sendable {
    public let object: String
    public let status: String
    public let apiVersion: String
    public let timestamp: Date

    enum CodingKeys: String, CodingKey {
        case object
        case status
        case apiVersion = "api_version"
        case timestamp
    }
}

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

// MARK: - SDK Internal License Model

/// Internal license model used by the SDK for caching and state management
public struct License: Codable, Equatable, Sendable {
    /// The license key
    public let licenseKey: String

    /// Device ID this license is activated on
    public let deviceId: String

    /// Activation ID (UUID) from the server
    public let activationId: String

    /// When the license was activated
    public let activatedAt: Date

    /// When the license was last validated
    public var lastValidated: Date

    /// Current validation state
    public var validation: ValidationResponse?

    enum CodingKeys: String, CodingKey {
        case licenseKey = "license_key"
        case deviceId = "device_id"
        case activationId = "activation_id"
        case activatedAt = "activated_at"
        case lastValidated = "last_validated"
        case validation
    }

    public init(
        licenseKey: String,
        deviceId: String,
        activationId: String,
        activatedAt: Date,
        lastValidated: Date,
        validation: ValidationResponse? = nil
    ) {
        self.licenseKey = licenseKey
        self.deviceId = deviceId
        self.activationId = activationId
        self.activatedAt = activatedAt
        self.lastValidated = lastValidated
        self.validation = validation
    }
}

// swiftlint:enable nesting
