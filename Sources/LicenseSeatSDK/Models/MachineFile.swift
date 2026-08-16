//
//  MachineFile.swift
//  LicenseSeatSDK
//
//  Encrypted, signed machine-file artifact and its checkout response.
//

import Foundation

// MARK: - Machine File (API Response)

/// A device-bound offline licensing artifact.
///
/// The `certificate` is a PEM-like armor whose body decodes to a small
/// envelope: an AES-256-GCM ciphertext plus an Ed25519 signature over that
/// ciphertext. The symmetric key is derived from the license key and the
/// device fingerprint, so the artifact can only be opened on the device it was
/// issued for. Use ``LicenseSeat/verifyMachineFile(_:publicKeyB64:licenseKey:fingerprint:)``
/// to verify and decrypt one; the certificate itself is opaque to callers.
public struct MachineFile: Codable, Equatable, Sendable {
    /// The only machine-file algorithm this SDK accepts.
    public static let algorithmIdentifier = "aes-256-gcm+ed25519"

    /// PEM-like certificate returned by the API.
    public let certificate: String

    /// Machine-file algorithm.
    public let algorithm: String

    /// Artifact lifetime in seconds, as reported by the issuing endpoint.
    public let ttl: Int

    /// Issue timestamp reported by the issuing endpoint.
    public let issuedAt: Date?

    /// Expiry timestamp reported by the issuing endpoint.
    public let expiresAt: Date?

    /// License key relationship ID.
    public let licenseKey: String

    /// Machine fingerprint relationship ID.
    public let fingerprint: String

    enum CodingKeys: String, CodingKey {
        case certificate
        case algorithm
        case ttl
        case issuedAt = "issued_at"
        case expiresAt = "expires_at"
        case licenseKey = "license_key"
        case fingerprint
    }

    public init(
        certificate: String,
        algorithm: String = MachineFile.algorithmIdentifier,
        ttl: Int = 0,
        issuedAt: Date? = nil,
        expiresAt: Date? = nil,
        licenseKey: String = "",
        fingerprint: String = ""
    ) {
        self.certificate = certificate
        self.algorithm = algorithm
        self.ttl = ttl
        self.issuedAt = issuedAt
        self.expiresAt = expiresAt
        self.licenseKey = licenseKey
        self.fingerprint = fingerprint
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        certificate = try container.decode(String.self, forKey: .certificate)
        algorithm = try container.decodeIfPresent(String.self, forKey: .algorithm)
            ?? MachineFile.algorithmIdentifier
        ttl = try container.decodeIfPresent(Int.self, forKey: .ttl) ?? 0
        issuedAt = try container.decodeIfPresent(Date.self, forKey: .issuedAt)
        expiresAt = try container.decodeIfPresent(Date.self, forKey: .expiresAt)
        licenseKey = try container.decodeIfPresent(String.self, forKey: .licenseKey) ?? ""
        fingerprint = try container.decodeIfPresent(String.self, forKey: .fingerprint) ?? ""
    }
}

// MARK: - Machine File Checkout Response

/// JSON:API document returned by `POST /products/{slug}/licenses/machine-file`.
///
/// The response is validated structurally before it can become a cached
/// artifact: unknown members, an unexpected object type, an unsupported
/// algorithm, an implausible lifetime, or inconsistent issue/expiry claims all
/// fail decoding rather than producing a partially trusted machine file.
struct MachineFileResponse: Decodable {
    /// Server-side clamp on machine-file lifetimes (100 leap years).
    static let maximumTTLSeconds = 36_600 * 86_400

    let machineFile: MachineFile

    private enum RootKeys: String, CodingKey {
        case data
    }

    private enum DataKeys: String, CodingKey {
        case type, attributes, relationships
    }

    private enum AttributeKeys: String, CodingKey {
        case certificate, algorithm, ttl, issued, expiry
    }

    private enum RelationshipKeys: String, CodingKey {
        case license, machine
    }

    private enum WrapperKeys: String, CodingKey {
        case data
    }

    private enum IdentifierKeys: String, CodingKey {
        case type, id
    }

    init(from decoder: Decoder) throws {
        try Self.requireExactMembers(
            in: decoder,
            keyedBy: RootKeys.self,
            expected: ["data"],
            context: "machine-file response"
        )
        let root = try decoder.container(keyedBy: RootKeys.self)

        try Self.requireExactMembers(
            in: root,
            forKey: RootKeys.data,
            expected: ["type", "attributes", "relationships"],
            context: "machine-file document"
        )
        let data = try root.nestedContainer(keyedBy: DataKeys.self, forKey: .data)
        guard try data.decode(String.self, forKey: .type) == "machine-files" else {
            throw Self.invalid("machine-file response object type is invalid")
        }

        let artifact = try Self.decodeAttributes(in: data)

        try Self.requireExactMembers(
            in: data,
            forKey: DataKeys.relationships,
            expected: ["license", "machine"],
            context: "machine-file relationships"
        )
        let relationships = try data.nestedContainer(
            keyedBy: RelationshipKeys.self,
            forKey: .relationships
        )
        let licenseKey = try Self.relationshipIdentifier(
            in: relationships,
            forKey: .license,
            expectedType: "licenses",
            maximumBytes: MachineFileFormat.maxLicenseKeyBytes
        )
        // The machine relationship echoes the fingerprint that was sent. It is
        // bounded rather than held to the 8 byte floor for new fingerprints so
        // a pre-floor activation issued by an older SDK can still refresh.
        let fingerprint = try Self.relationshipIdentifier(
            in: relationships,
            forKey: .machine,
            expectedType: "machines",
            maximumBytes: MachineFileFormat.maxIdentityBytes
        )

        machineFile = MachineFile(
            certificate: artifact.certificate,
            algorithm: artifact.algorithm,
            ttl: artifact.ttl,
            issuedAt: artifact.issuedAt,
            expiresAt: artifact.expiresAt,
            licenseKey: licenseKey,
            fingerprint: fingerprint
        )
    }

    /// Decode and bound the `attributes` object.
    private static func decodeAttributes(
        in data: KeyedDecodingContainer<DataKeys>
    ) throws -> MachineFile {
        try requireExactMembers(
            in: data,
            forKey: DataKeys.attributes,
            expected: ["certificate", "algorithm", "ttl", "issued", "expiry"],
            context: "machine-file attributes"
        )
        let attributes = try data.nestedContainer(
            keyedBy: AttributeKeys.self,
            forKey: .attributes
        )

        let certificate = try attributes.decode(String.self, forKey: .certificate)
        guard !certificate.isEmpty,
              certificate.utf8.count <= MachineFileFormat.maxCertificateBytes else {
            throw invalid("machine-file certificate is invalid")
        }
        let algorithm = try attributes.decode(String.self, forKey: .algorithm)
        guard algorithm == MachineFile.algorithmIdentifier else {
            throw invalid("machine-file algorithm is invalid")
        }
        let ttl = try attributes.decode(Int.self, forKey: .ttl)
        guard (1...maximumTTLSeconds).contains(ttl) else {
            throw invalid("machine-file lifetime is invalid")
        }
        guard let issuedAt = ISO8601Timestamp.parse(
            try attributes.decode(String.self, forKey: .issued)
        ) else {
            throw invalid("machine-file issued time is invalid")
        }
        guard let expiresAt = ISO8601Timestamp.parse(
            try attributes.decode(String.self, forKey: .expiry)
        ) else {
            throw invalid("machine-file expiry is invalid")
        }
        // The issuing controller stamps `issued`/`expiry` from a second clock
        // read than the signed payload uses, so allow the same two second
        // tolerance the other SDKs allow before calling the claims inconsistent.
        guard abs(expiresAt.timeIntervalSince(issuedAt) - Double(ttl)) <= 2 else {
            throw invalid("machine-file lifetime claims are inconsistent")
        }

        return MachineFile(
            certificate: certificate,
            algorithm: algorithm,
            ttl: ttl,
            issuedAt: issuedAt,
            expiresAt: expiresAt
        )
    }

    private static func relationshipIdentifier(
        in container: KeyedDecodingContainer<RelationshipKeys>,
        forKey key: RelationshipKeys,
        expectedType: String,
        maximumBytes: Int
    ) throws -> String {
        try requireExactMembers(
            in: container,
            forKey: key,
            expected: ["data"],
            context: "machine-file \(key.stringValue) relationship"
        )
        let wrapper = try container.nestedContainer(keyedBy: WrapperKeys.self, forKey: key)
        try requireExactMembers(
            in: wrapper,
            forKey: WrapperKeys.data,
            expected: ["type", "id"],
            context: "machine-file \(key.stringValue) relationship"
        )
        let identifier = try wrapper.nestedContainer(
            keyedBy: IdentifierKeys.self,
            forKey: .data
        )
        guard try identifier.decode(String.self, forKey: .type) == expectedType else {
            throw invalid("machine-file \(key.stringValue) relationship is invalid")
        }
        let value = try identifier.decode(String.self, forKey: .id)
        guard MachineFileFormat.safeText(value, maximumBytes: maximumBytes) else {
            throw invalid("machine-file \(key.stringValue) relationship is invalid")
        }
        return value
    }

    /// Reject unknown members. `allKeys` on a fixed `CodingKey` enum silently
    /// drops names it cannot represent, so member names are enumerated through
    /// a dynamic key type instead.
    private static func requireExactMembers<Key: CodingKey>(
        in container: KeyedDecodingContainer<Key>,
        forKey key: Key,
        expected: Set<String>,
        context: String
    ) throws {
        let nested = try container.nestedContainer(
            keyedBy: AnyCodingKey.self,
            forKey: key
        )
        guard Set(nested.allKeys.map(\.stringValue)) == expected else {
            throw invalid("\(context) contains unsupported or missing members")
        }
    }

    private static func requireExactMembers<Key: CodingKey>(
        in decoder: Decoder,
        keyedBy: Key.Type,
        expected: Set<String>,
        context: String
    ) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        guard Set(container.allKeys.map(\.stringValue)) == expected else {
            throw invalid("\(context) contains unsupported or missing members")
        }
    }

    private static func invalid(_ message: String) -> DecodingError {
        DecodingError.dataCorrupted(
            DecodingError.Context(codingPath: [], debugDescription: message)
        )
    }
}

/// Dynamic coding key used to enumerate the member names actually present.
struct AnyCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int?

    init?(stringValue: String) {
        self.stringValue = stringValue
        self.intValue = nil
    }

    init?(intValue: Int) {
        self.stringValue = String(intValue)
        self.intValue = intValue
    }
}

