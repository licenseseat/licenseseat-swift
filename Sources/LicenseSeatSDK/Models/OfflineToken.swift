//
//  OfflineToken.swift
//  LicenseSeatSDK
//
//  Signed offline-token and public-key response models.
//

import Foundation

// Token payload, entitlement, and signature are part of one wire envelope.
// swiftlint:disable nesting

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
        /// Presence is retained internally so an alias-only signed payload can
        /// be decoded and rejected as a canonical-payload mismatch instead of
        /// being silently treated as the canonical fingerprint member.
        private let decodedFingerprint: String?

        /// Canonical device binding covered by the signature. Missing
        /// canonical data is exposed as an empty value and is rejected before
        /// signature authority is granted.
        public var fingerprint: String { decodedFingerprint ?? "" }

        /// Source-compatible spelling retained for 0.4.x callers. Signed
        /// payloads themselves accept only the canonical fingerprint member.
        public var deviceId: String? { decodedFingerprint }
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
            // The signed payload accepts ONLY the canonical `fingerprint`
            // spelling, which is exactly what the Ruby signer emits.
            // Decode-only aliases (`device_id`/`device_fingerprint`) would
            // advertise compatibility the verifier does not grant: encoding
            // always re-emits `fingerprint`, so an alias-keyed canonical
            // fails `canonicalPayloadMatchesToken` despite a valid
            // signature. Alias handling for ONLINE responses stays in
            // DecodingCompatibility.swift.
            case fingerprint
            case iat, exp, nbf
            case licenseExpiresAt = "license_expires_at"
            case kid
            case entitlements
            case metadata
        }

        public init(
            schemaVersion: Int,
            licenseKey: String,
            productSlug: String,
            planKey: String,
            mode: String,
            seatLimit: Int?,
            deviceId: String?,
            iat: Int,
            exp: Int,
            nbf: Int,
            licenseExpiresAt: Int?,
            kid: String,
            entitlements: [TokenEntitlement],
            metadata: [String: AnyCodable]?
        ) {
            self.schemaVersion = schemaVersion
            self.licenseKey = licenseKey
            self.productSlug = productSlug
            self.planKey = planKey
            self.mode = mode
            self.seatLimit = seatLimit
            self.decodedFingerprint = deviceId
            self.iat = iat
            self.exp = exp
            self.nbf = nbf
            self.licenseExpiresAt = licenseExpiresAt
            self.kid = kid
            self.entitlements = entitlements
            self.metadata = metadata
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
            licenseKey = try container.decode(String.self, forKey: .licenseKey)
            productSlug = try container.decode(String.self, forKey: .productSlug)
            planKey = try container.decode(String.self, forKey: .planKey)
            mode = try container.decode(String.self, forKey: .mode)
            seatLimit = try container.decodeIfPresent(Int.self, forKey: .seatLimit)
            decodedFingerprint = try container.decodeIfPresent(
                String.self,
                forKey: .fingerprint
            )
            iat = try container.decode(Int.self, forKey: .iat)
            exp = try container.decode(Int.self, forKey: .exp)
            nbf = try container.decode(Int.self, forKey: .nbf)
            licenseExpiresAt = try container.decodeIfPresent(Int.self, forKey: .licenseExpiresAt)
            kid = try container.decode(String.self, forKey: .kid)
            entitlements = try container.decode([TokenEntitlement].self, forKey: .entitlements)
            metadata = try container.decodeIfPresent([String: AnyCodable].self, forKey: .metadata)
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(schemaVersion, forKey: .schemaVersion)
            try container.encode(licenseKey, forKey: .licenseKey)
            try container.encode(productSlug, forKey: .productSlug)
            try container.encode(planKey, forKey: .planKey)
            try container.encode(mode, forKey: .mode)
            try container.encodeIfPresent(seatLimit, forKey: .seatLimit)
            try container.encodeIfPresent(
                decodedFingerprint,
                forKey: .fingerprint
            )
            try container.encode(iat, forKey: .iat)
            try container.encode(exp, forKey: .exp)
            try container.encode(nbf, forKey: .nbf)
            try container.encodeIfPresent(licenseExpiresAt, forKey: .licenseExpiresAt)
            try container.encode(kid, forKey: .kid)
            try container.encode(entitlements, forKey: .entitlements)
            try container.encodeIfPresent(metadata, forKey: .metadata)
        }

        public init(
            schemaVersion: Int,
            licenseKey: String,
            productSlug: String,
            planKey: String,
            mode: String,
            seatLimit: Int?,
            fingerprint: String,
            iat: Int,
            exp: Int,
            nbf: Int,
            licenseExpiresAt: Int?,
            kid: String,
            entitlements: [TokenEntitlement],
            metadata: [String: AnyCodable]?
        ) {
            self.schemaVersion = schemaVersion
            self.licenseKey = licenseKey
            self.productSlug = productSlug
            self.planKey = planKey
            self.mode = mode
            self.seatLimit = seatLimit
            self.decodedFingerprint = fingerprint
            self.iat = iat
            self.exp = exp
            self.nbf = nbf
            self.licenseExpiresAt = licenseExpiresAt
            self.kid = kid
            self.entitlements = entitlements
            self.metadata = metadata
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

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(key, forKey: .key)

            // The Ruby signer includes `expires_at: null` for perpetual
            // entitlements. Preserve that explicit null when reconstructing
            // the token for the canonical sibling-payload integrity check.
            if let expiresAt {
                try container.encode(expiresAt, forKey: .expiresAt)
            } else {
                try container.encodeNil(forKey: .expiresAt)
            }
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

// swiftlint:enable nesting
