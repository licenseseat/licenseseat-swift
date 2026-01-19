//
//  License.swift
//  LicenseSeatSDK
//
//  Created by LicenseSeat on 2025.
//  Copyright © 2025 LicenseSeat. All rights reserved.
//

import Foundation

/// Represents an activated license
public struct License: Codable, Equatable, Sendable {
    /// The license key
    public let licenseKey: String
    
    /// Device identifier this license is activated on
    public let deviceIdentifier: String
    
    /// Activation details
    public let activation: ActivationResult
    
    /// When the license was activated
    public let activatedAt: Date
    
    /// When the license was last validated
    public var lastValidated: Date
    
    /// Current validation state
    public var validation: LicenseValidationResult?
    
    enum CodingKeys: String, CodingKey {
        case licenseKey = "license_key"
        case deviceIdentifier = "device_identifier"
        case activation
        case activatedAt = "activated_at"
        case lastValidated = "last_validated"
        case validation
    }
}

/// Result of a license activation
public struct ActivationResult: Codable, Equatable, Sendable {
    /// Activation ID (stored as String for flexibility; API may return Int or String)
    public let id: String

    /// When the activation occurred
    public let activatedAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case activatedAt = "activated_at"
    }

    // Custom decoding to handle both Int and String for `id`
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        // Try decoding as String first, then fall back to Int
        if let stringId = try? container.decode(String.self, forKey: .id) {
            self.id = stringId
        } else if let intId = try? container.decode(Int.self, forKey: .id) {
            self.id = String(intId)
        } else {
            throw DecodingError.typeMismatch(
                String.self,
                DecodingError.Context(
                    codingPath: container.codingPath + [CodingKeys.id],
                    debugDescription: "Expected String or Int for id"
                )
            )
        }

        self.activatedAt = try container.decode(Date.self, forKey: .activatedAt)
    }

    public init(id: String, activatedAt: Date) {
        self.id = id
        self.activatedAt = activatedAt
    }
}

/// Result of a license validation
public struct LicenseValidationResult: Codable, Equatable, Sendable {
    /// Whether the license is valid
    public let valid: Bool
    
    /// Reason for invalidity (if applicable)
    public let reason: String?
    
    /// Whether this is an offline validation
    public let offline: Bool
    
    /// Reason code for offline validation failures
    public let reasonCode: String?
    
    /// Whether this is an optimistic validation
    public let optimistic: Bool?
    
    /// Active entitlements
    public let activeEntitlements: [Entitlement]?
    
    enum CodingKeys: String, CodingKey {
        case valid
        case reason
        case offline
        case reasonCode = "reason_code"
        case optimistic
        case activeEntitlements = "active_entitlements"
    }
    
    public init(
        valid: Bool,
        reason: String? = nil,
        offline: Bool,
        reasonCode: String? = nil,
        optimistic: Bool? = nil,
        activeEntitlements: [Entitlement]? = nil
    ) {
        self.valid = valid
        self.reason = reason
        self.offline = offline
        self.reasonCode = reasonCode
        self.optimistic = optimistic
        self.activeEntitlements = activeEntitlements
    }
    
    // Custom decoding to handle multiple API response formats:
    // 1. Top-level active_entitlements (direct format)
    // 2. Nested license.active_entitlements (API /licenses/validate format)
    // 3. active_ents (offline payload abbreviation)
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.valid = try container.decode(Bool.self, forKey: .valid)
        self.reason = try container.decodeIfPresent(String.self, forKey: .reason)
        // Default to `false` when key is absent to be backwards-compatible with older servers
        self.offline = try container.decodeIfPresent(Bool.self, forKey: .offline) ?? false
        self.reasonCode = try container.decodeIfPresent(String.self, forKey: .reasonCode)
        self.optimistic = try container.decodeIfPresent(Bool.self, forKey: .optimistic)

        // Try multiple paths to find entitlements
        var decodedEntitlements: [Entitlement]?

        // 1. Try top-level active_entitlements (direct format)
        decodedEntitlements = try container.decodeIfPresent([Entitlement].self, forKey: .activeEntitlements)

        // 2. Try nested license.active_entitlements (API /licenses/validate format)
        // The API returns: { "valid": true, "license": { "active_entitlements": [...] } }
        if decodedEntitlements == nil {
            struct LicenseKey: CodingKey {
                var stringValue: String
                init?(stringValue: String) { self.stringValue = stringValue }
                var intValue: Int?
                init?(intValue: Int) { return nil }
            }
            let rootContainer = try decoder.container(keyedBy: LicenseKey.self)
            if let licenseKey = LicenseKey(stringValue: "license"),
               let licenseContainer = try? rootContainer.nestedContainer(keyedBy: CodingKeys.self, forKey: licenseKey) {
                decodedEntitlements = try licenseContainer.decodeIfPresent([Entitlement].self, forKey: .activeEntitlements)
            }
        }

        // 3. Fallback to abbreviated key used by offline payloads
        if decodedEntitlements == nil {
            struct DynamicKey: CodingKey {
                var stringValue: String
                init?(stringValue: String) { self.stringValue = stringValue }
                var intValue: Int?
                init?(intValue: Int) { return nil }
            }
            let dynContainer = try decoder.container(keyedBy: DynamicKey.self)
            if let activeEntsKey = DynamicKey(stringValue: "active_ents"),
               let rawEnts = try dynContainer.decodeIfPresent([[String: AnyCodable]].self, forKey: activeEntsKey) {
                let isoFormatter = ISO8601DateFormatter()
                decodedEntitlements = rawEnts.compactMap { dict -> Entitlement? in
                    guard let keyVal = dict["key"]?.value as? String else { return nil }
                    let name = dict["name"]?.value as? String
                    let description = dict["description"]?.value as? String
                    let expiresStr = dict["expires_at"]?.value as? String
                    let expiresAt = expiresStr.flatMap { isoFormatter.date(from: $0) }
                    let metaAny = dict["metadata"]?.value as? [String: Any]
                    let metadata = metaAny?.mapValues { AnyCodable($0) }
                    return Entitlement(
                        key: keyVal,
                        name: name,
                        description: description,
                        expiresAt: expiresAt,
                        metadata: metadata
                    )
                }
            }
        }
        self.activeEntitlements = decodedEntitlements
    }
    
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(valid, forKey: .valid)
        try container.encodeIfPresent(reason, forKey: .reason)
        try container.encode(offline, forKey: .offline)
        try container.encodeIfPresent(reasonCode, forKey: .reasonCode)
        try container.encodeIfPresent(optimistic, forKey: .optimistic)
        try container.encodeIfPresent(activeEntitlements, forKey: .activeEntitlements)
    }
}

/// Represents an entitlement
public struct Entitlement: Codable, Equatable, Sendable {
    /// Unique key for the entitlement
    public let key: String
    
    /// Display name
    public let name: String?
    
    /// Description
    public let description: String?
    
    /// Expiration date (if applicable)
    public let expiresAt: Date?
    
    /// Additional metadata
    public let metadata: [String: AnyCodable]?
    
    enum CodingKeys: String, CodingKey {
        case key
        case name
        case description
        case expiresAt = "expires_at"
        case metadata
    }
}

/// Activation payload
struct ActivationPayload: Codable {
    let licenseKey: String
    let deviceIdentifier: String
    var metadata: [String: Any]?
    var softwareReleaseDate: String?
    
    enum CodingKeys: String, CodingKey {
        case licenseKey = "license_key"
        case deviceIdentifier = "device_identifier"
        case metadata
        case softwareReleaseDate = "software_release_date"
    }
    
    // Memberwise init
    init(licenseKey: String, deviceIdentifier: String, metadata: [String: Any]? = nil, softwareReleaseDate: String? = nil) {
        self.licenseKey = licenseKey
        self.deviceIdentifier = deviceIdentifier
        self.metadata = metadata
        self.softwareReleaseDate = softwareReleaseDate
    }
    
    // Custom encoding to handle [String: Any] metadata
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(licenseKey, forKey: .licenseKey)
        try container.encode(deviceIdentifier, forKey: .deviceIdentifier)
        try container.encodeIfPresent(softwareReleaseDate, forKey: .softwareReleaseDate)
        
        if let metadata = metadata {
            let encodableMetadata = metadata.mapValues { AnyCodable($0) }
            try container.encode(encodableMetadata, forKey: .metadata)
        }
    }
    
    // Custom decoding to handle [String: Any] metadata
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        licenseKey = try container.decode(String.self, forKey: .licenseKey)
        deviceIdentifier = try container.decode(String.self, forKey: .deviceIdentifier)
        softwareReleaseDate = try container.decodeIfPresent(String.self, forKey: .softwareReleaseDate)
        
        if let metadataDict = try container.decodeIfPresent([String: AnyCodable].self, forKey: .metadata) {
            metadata = metadataDict.mapValues { $0.value }
        } else {
            metadata = nil
        }
    }
}

/// Offline license structure
struct OfflineLicense: Codable {
    let payload: [String: Any]?
    let signatureB64u: String?
    let kid: String?
    
    enum CodingKeys: String, CodingKey {
        case payload
        case signatureB64u = "signature_b64u"
        case kid
    }
    
    // Memberwise init
    init(payload: [String: Any]? = nil, signatureB64u: String? = nil, kid: String? = nil) {
        self.payload = payload
        self.signatureB64u = signatureB64u
        self.kid = kid
    }
    
    // Custom decoding for [String: Any] payload
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        signatureB64u = try container.decodeIfPresent(String.self, forKey: .signatureB64u)
        kid = try container.decodeIfPresent(String.self, forKey: .kid)
        
        if let payloadData = try? container.decode([String: AnyCodable].self, forKey: .payload) {
            payload = payloadData.mapValues { $0.value }
        } else {
            payload = nil
        }
    }
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(signatureB64u, forKey: .signatureB64u)
        try container.encodeIfPresent(kid, forKey: .kid)
        
        if let payload = payload {
            let encodablePayload = payload.mapValues { AnyCodable($0) }
            try container.encode(encodablePayload, forKey: .payload)
        }
    }
} 