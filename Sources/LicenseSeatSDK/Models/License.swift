//
//  License.swift
//  LicenseSeatSDK
//
//  Created by LicenseSeat on 2025.
//  Copyright © 2025 LicenseSeat. All rights reserved.
//

import Foundation

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

    /// Additional metadata
    public let metadata: [String: AnyCodable]?

    enum CodingKeys: String, CodingKey {
        case key
        case expiresAt = "expires_at"
        case metadata
    }

    public init(key: String, expiresAt: Date? = nil, metadata: [String: AnyCodable]? = nil) {
        self.key = key
        self.expiresAt = expiresAt
        self.metadata = metadata
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
        case deviceId = "device_id"
        case deviceName = "device_name"
        case licenseKey = "license_key"
        case activatedAt = "activated_at"
        case deactivatedAt = "deactivated_at"
        case ipAddress = "ip_address"
        case metadata
        case license
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
            case deviceId = "device_id"
            case deviceName = "device_name"
            case licenseKey = "license_key"
            case activatedAt = "activated_at"
            case deactivatedAt = "deactivated_at"
            case ipAddress = "ip_address"
            case metadata
        }
    }
}

// MARK: - Offline Token (API Response)

/// Offline token as returned by the API
/// Response format: `{"object": "offline_token", "token": {...}, "signature": {...}, "canonical": "..."}`
public struct OfflineTokenResponse: Codable, Equatable, Sendable {
    public let object: String
    public let token: TokenPayload
    public let signature: Signature
    public let canonical: String

    /// Token payload containing license information
    public struct TokenPayload: Codable, Equatable, Sendable {
        public let schemaVersion: Int
        public let licenseKey: String
        public let productSlug: String
        public let planKey: String
        public let mode: String
        public let seatLimit: Int?
        public let deviceId: String?
        public let iat: Int
        public let exp: Int
        public let nbf: Int
        public let licenseExpiresAt: Int?
        public let kid: String
        public let entitlements: [TokenEntitlement]
        public let metadata: [String: AnyCodable]?

        enum CodingKeys: String, CodingKey {
            case schemaVersion = "schema_version"
            case licenseKey = "license_key"
            case productSlug = "product_slug"
            case planKey = "plan_key"
            case mode
            case seatLimit = "seat_limit"
            case deviceId = "device_id"
            case iat, exp, nbf
            case licenseExpiresAt = "license_expires_at"
            case kid
            case entitlements
            case metadata
        }
    }

    /// Entitlement in offline token (uses Unix timestamps)
    public struct TokenEntitlement: Codable, Equatable, Sendable {
        public let key: String
        public let expiresAt: Int?

        enum CodingKeys: String, CodingKey {
            case key
            case expiresAt = "expires_at"
        }
    }

    /// Signature block
    public struct Signature: Codable, Equatable, Sendable {
        public let algorithm: String
        public let keyId: String
        public let value: String

        enum CodingKeys: String, CodingKey {
            case algorithm
            case keyId = "key_id"
            case value
        }
    }
}

// MARK: - Signing Key (API Response)

/// Signing key as returned by the API
/// Response format: `{"object": "signing_key", "key_id": "...", "public_key": "...", ...}`
public struct SigningKeyResponse: Codable, Equatable, Sendable {
    public let object: String
    public let keyId: String
    public let algorithm: String
    public let publicKey: String
    public let createdAt: Date?
    public let status: String

    enum CodingKeys: String, CodingKey {
        case object
        case keyId = "key_id"
        case algorithm
        case publicKey = "public_key"
        case createdAt = "created_at"
        case status
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
