//
//  MachineFileFormat.swift
//  LicenseSeatSDK
//
//  Wire constants, shared predicates, and machine-file verification inputs.
//

import Foundation

/// Fail-closed failure raised by every machine-file verification step.
///
/// `code` uses the same vocabulary as the offline-token verifier so a host can
/// branch on one set of offline failure reasons regardless of which artifact
/// granted authority.
struct MachineFileVerificationFailure: Error {
    let code: String
    let message: String
}

/// Wire constants and pure predicates for the `aes-256-gcm+ed25519` artifact.
///
/// Kept outside the main-actor SDK type because the checkout response is
/// decoded off the main actor.
enum MachineFileFormat {
    static let algorithm = MachineFile.algorithmIdentifier
    static let schemaVersion = 2

    static let beginArmor = "-----BEGIN MACHINE FILE-----"
    static let endArmor = "-----END MACHINE FILE-----"
    static let armorLineBytes = 64

    static let maxCertificateBytes = 1024 * 1024
    static let maxEncryptedTextBytes = 768 * 1024
    static let maxCiphertextBytes = 512 * 1024
    static let maxTTLSeconds = 36_600 * 86_400
    static let maxLifetimeSeconds = 100 * 366 * 86_400
    static let maxGraceSeconds = 30 * 86_400

    static let maxIdentityBytes = 255
    static let maxLicenseKeyBytes = 512
    static let maxSignatureTextBytes = 128
    static let maxEntitlements = 500
    static let maxFingerprintComponents = 64
    static let maxComponentKeyBytes = 100
    static let maxComponentValueBytes = 1_024
    static let maxMetadataEntries = 256
    static let maxMetadataBytes = 128 * 1024

    static let nonceBytes = 12
    static let tagBytes = 16
    static let signatureBytes = 64
    static let publicKeyBytes = 32

    /// Latest instant this SDK treats as a representable signed timestamp
    /// (9999-12-31T23:59:59Z). Anything beyond it is a malformed claim, not a
    /// long-lived grant, and rejecting it keeps every later addition in range.
    static let maxRepresentableTimestamp = 253_402_300_799

    static let licenseModes: Set<String> = ["hardware_locked", "floating", "named_user"]

    static func safeText(
        _ value: String,
        minimumBytes: Int = 1,
        maximumBytes: Int
    ) -> Bool {
        LicenseSeat.safeOfflineText(
            value,
            minimumBytes: minimumBytes,
            maximumBytes: maximumBytes
        )
    }

    static func validKeyId(_ value: String) -> Bool {
        LicenseSeat.validOfflineKeyId(value)
    }

    static func validEntitlementKey(_ value: String) -> Bool {
        value.range(
            of: "^[a-z0-9][a-z0-9_-]{0,99}$",
            options: .regularExpression
        ) != nil
    }

    static func isRepresentableTimestamp(_ value: Int) -> Bool {
        (1...maxRepresentableTimestamp).contains(value)
    }

    static func constantTimeEqual(_ first: String, _ second: String) -> Bool {
        LicenseSeat.constantTimeEqual(first, second)
    }
}

/// Public envelope wrapped by the certificate armor.
struct MachineFileEnvelope {
    let enc: String
    let signature: String
    let algorithm: String
    let keyId: String
}

/// Everything a machine file must be verified *against*.
///
/// Bundling these keeps the identity a verification is bound to inseparable
/// from the verification itself: no call site can supply four of the five and
/// silently inherit a default for the fifth.
struct MachineFileVerificationContext {
    let licenseKey: String
    let fingerprint: String
    let publicKeyB64: String
    let productSlug: String
    let now: Date

    init(
        licenseKey: String,
        fingerprint: String,
        publicKeyB64: String,
        productSlug: String,
        now: Date = Date()
    ) {
        self.licenseKey = licenseKey
        self.fingerprint = fingerprint
        self.publicKeyB64 = publicKeyB64
        self.productSlug = productSlug
        self.now = now
    }
}
