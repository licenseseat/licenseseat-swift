//
//  MachineFilePayload.swift
//  LicenseSeatSDK
//
//  The decrypted, signature-covered contents of a machine file.
//

import Foundation

// MARK: - Decrypted Payload

/// The decrypted, signature-covered contents of a machine file.
///
/// A value of this type is only produced after the Ed25519 signature, the
/// AES-256-GCM authentication tag, the device binding, and every time claim
/// have been checked. It is therefore safe to read as an authorization input.
public struct MachineFilePayload: Codable, Equatable, Sendable {
    /// Payload schema version (always 2 for this format).
    public let schemaVersion: Int

    /// Human-readable issue timestamp.
    public let issued: String

    /// Issued-at Unix timestamp.
    public let iat: Int

    /// Human-readable expiry timestamp.
    public let expiry: String

    /// Expiry Unix timestamp.
    public let exp: Int

    /// Not-before Unix timestamp.
    public let nbf: Int

    /// Signed lifetime in seconds.
    public let ttl: Int

    /// Signed grace period in seconds, applied after ``exp``.
    public let gracePeriod: Int

    /// License key bound to this artifact.
    public let licenseKey: String

    /// Product slug bound through the machine relationship.
    public let productSlug: String

    /// Underlying license expiration, when the license is time limited.
    public let licenseExpiresAt: Int?

    /// Signing key id, matched against the outer envelope.
    public let keyId: String

    /// SDK version recorded by the issuer.
    public let sdkVersion: String?

    /// Machine/activation id.
    public let machineId: String

    /// Device fingerprint embedded in the signed payload.
    public let fingerprint: String

    /// Optional structured fingerprint components.
    public let fingerprintComponents: [String: String]

    /// Human-readable device name.
    public let deviceName: String

    /// Platform name.
    public let platform: String

    /// Activation creation timestamp.
    public let createdAt: Date?

    /// Activation/device metadata.
    public let metadata: [String: AnyCodable]

    /// Embedded license object, when the issuer included license data.
    public let license: LicenseResponse?

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case issued
        case iat
        case expiry
        case exp
        case nbf
        case ttl
        case gracePeriod = "grace_period"
        case licenseKey = "license_key"
        case productSlug = "product_slug"
        case licenseExpiresAt = "license_expires_at"
        case keyId = "key_id"
        case sdkVersion = "sdk_version"
        case machineId = "machine_id"
        case fingerprint
        case fingerprintComponents = "fingerprint_components"
        case deviceName = "device_name"
        case platform
        case createdAt = "created_at"
        case metadata
        case license
    }

    // swiftlint:disable:next function_default_parameter_at_end
    public init(
        schemaVersion: Int,
        issued: String,
        iat: Int,
        expiry: String,
        exp: Int,
        nbf: Int,
        ttl: Int,
        gracePeriod: Int,
        licenseKey: String,
        productSlug: String,
        licenseExpiresAt: Int?,
        keyId: String,
        sdkVersion: String?,
        machineId: String,
        fingerprint: String,
        fingerprintComponents: [String: String],
        deviceName: String,
        platform: String,
        createdAt: Date?,
        metadata: [String: AnyCodable],
        license: LicenseResponse?
    ) {
        self.schemaVersion = schemaVersion
        self.issued = issued
        self.iat = iat
        self.expiry = expiry
        self.exp = exp
        self.nbf = nbf
        self.ttl = ttl
        self.gracePeriod = gracePeriod
        self.licenseKey = licenseKey
        self.productSlug = productSlug
        self.licenseExpiresAt = licenseExpiresAt
        self.keyId = keyId
        self.sdkVersion = sdkVersion
        self.machineId = machineId
        self.fingerprint = fingerprint
        self.fingerprintComponents = fingerprintComponents
        self.deviceName = deviceName
        self.platform = platform
        self.createdAt = createdAt
        self.metadata = metadata
        self.license = license
    }

    /// The instant this artifact stops granting authority, grace included.
    public var effectiveExpiry: Date {
        Date(timeIntervalSince1970: Double(exp) + Double(gracePeriod))
    }

    /// Whether an entitlement is currently active in the embedded license.
    ///
    /// This is a convenience for an already verified payload; it performs no
    /// cryptographic verification of its own.
    public func hasEntitlement(_ entitlementKey: String) -> Bool {
        let now = Date()
        guard let license,
              license.status.caseInsensitiveCompare("active") == .orderedSame,
              license.startsAt.map({ $0 <= now }) ?? true,
              license.expiresAt.map({ $0 > now }) ?? true else {
            return false
        }
        guard let entitlement = license.activeEntitlements.first(
            where: { $0.key == entitlementKey }
        ) else {
            return false
        }
        return entitlement.expiresAt.map { $0 > now } ?? true
    }
}

// MARK: - Verification Result

/// Outcome of local machine-file verification.
public struct MachineFileVerificationResult: Equatable, Sendable {
    /// Whether the machine file is valid for this device and license.
    public let valid: Bool

    /// Machine-readable failure code, using the SDK's offline vocabulary
    /// (`signature_invalid`, `decryption_failed`, `token_expired`, …).
    public let code: String?

    /// Human-readable failure description.
    public let message: String?

    /// Decrypted payload, present only when ``valid`` is `true`.
    public let payload: MachineFilePayload?

    init(
        valid: Bool,
        code: String? = nil,
        message: String? = nil,
        payload: MachineFilePayload? = nil
    ) {
        self.valid = valid
        self.code = code
        self.message = message
        self.payload = payload
    }
}

// MARK: - Timestamp Parsing

/// RFC 3339 parsing for the signed timestamps the API emits.
enum ISO8601Timestamp {
    static func parse(_ value: String) -> Date? {
        guard !value.isEmpty, value.utf8.count <= 64 else { return nil }

        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) {
            return date
        }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: value)
    }
}

