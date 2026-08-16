//
//  LicenseSeat+MachineFileCrypto.swift
//  LicenseSeatSDK
//
//  Armor parsing, Ed25519 verification, and AES-256-GCM decryption.
//

import Foundation
#if canImport(CryptoKit)
import CryptoKit
#elseif canImport(Crypto)
import Crypto
#endif

extension LicenseSeat {

    // MARK: - Envelope

    /// Decode the PEM-like armor into its four-member envelope.
    ///
    /// Nothing here is trusted yet: the armor shape, the Base64 alphabet, the
    /// JSON grammar, the exact member set, and every member's bounds are all
    /// checked before the signature is even considered.
    func parseMachineFileEnvelope(
        _ certificate: String
    ) throws -> MachineFileEnvelope {
        guard !certificate.isEmpty,
              certificate.utf8.count <= MachineFileFormat.maxCertificateBytes else {
            throw MachineFileVerificationFailure(
                code: "invalid_machine_file",
                message: "Machine file certificate is empty or too large"
            )
        }

        let body = try machineFileArmorBody(certificate)
        guard let decoded = try? Base64URL.decode(body),
              decoded.count <= MachineFileFormat.maxEncryptedTextBytes else {
            throw MachineFileVerificationFailure(
                code: "invalid_machine_file",
                message: "Invalid machine file encoding"
            )
        }
        guard (try? StrictJSON.validate(decoded, limits: .signedPayload)) != nil,
              let object = try? JSONSerialization.jsonObject(with: decoded),
              let envelope = object as? [String: Any],
              Set(envelope.keys) == ["enc", "sig", "alg", "kid"],
              let enc = envelope["enc"] as? String,
              let signature = envelope["sig"] as? String,
              let algorithm = envelope["alg"] as? String,
              let keyId = envelope["kid"] as? String else {
            throw MachineFileVerificationFailure(
                code: "invalid_machine_file",
                message: "Invalid machine file envelope"
            )
        }
        guard !enc.isEmpty,
              enc.utf8.count <= MachineFileFormat.maxEncryptedTextBytes,
              MachineFileFormat.safeText(
                  signature,
                  maximumBytes: MachineFileFormat.maxSignatureTextBytes
              ),
              algorithm == MachineFileFormat.algorithm,
              MachineFileFormat.validKeyId(keyId) else {
            throw MachineFileVerificationFailure(
                code: "invalid_machine_file",
                message: "Machine file envelope is incomplete"
            )
        }

        return MachineFileEnvelope(
            enc: enc,
            signature: signature,
            algorithm: algorithm,
            keyId: keyId
        )
    }

    /// Strip and validate the armor, returning the joined Base64 body.
    private func machineFileArmorBody(_ certificate: String) throws -> String {
        let lines = certificate
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard lines.count >= 3,
              lines.first == MachineFileFormat.beginArmor,
              lines.last == MachineFileFormat.endArmor else {
            throw MachineFileVerificationFailure(
                code: "invalid_machine_file",
                message: "Invalid machine file format"
            )
        }

        let body = lines[1..<(lines.count - 1)]
        guard body.allSatisfy({ line in
            !line.isEmpty &&
                line.utf8.count <= MachineFileFormat.armorLineBytes &&
                line.range(of: "^[A-Za-z0-9+/=]+$", options: .regularExpression) != nil
        }) else {
            throw MachineFileVerificationFailure(
                code: "invalid_machine_file",
                message: "Invalid machine file format"
            )
        }
        return body.joined()
    }

    /// Extract the signing-key id from a certificate without verifying it.
    ///
    /// Used to decide which public key to resolve. The id is structurally
    /// validated but carries no authority until the signature verifies.
    func machineFileKeyId(_ machineFile: MachineFile) -> String? {
        try? parseMachineFileEnvelope(machineFile.certificate).keyId
    }

    // MARK: - Signature

    /// Verify the Ed25519 signature over `"machine/" + enc`.
    ///
    /// This runs before any decryption so an attacker-supplied ciphertext can
    /// never reach the AES implementation without an authentic signature.
    func verifyMachineFileSignature(
        _ envelope: MachineFileEnvelope,
        publicKeyB64: String
    ) throws {
        #if canImport(CryptoKit) || canImport(Crypto)
        guard let publicKeyData = try? Base64URL.decode(publicKeyB64),
              publicKeyData.count == MachineFileFormat.publicKeyBytes,
              let publicKey = try? Curve25519.Signing.PublicKey(
                  rawRepresentation: publicKeyData
              ) else {
            throw MachineFileVerificationFailure(
                code: "invalid_public_key",
                message: "Machine-file signing key is invalid"
            )
        }
        guard let signature = try? Base64URL.decode(envelope.signature),
              signature.count == MachineFileFormat.signatureBytes else {
            throw MachineFileVerificationFailure(
                code: "signature_invalid",
                message: "Machine file signature is malformed"
            )
        }
        let message = Data("machine/\(envelope.enc)".utf8)
        guard publicKey.isValidSignature(signature, for: message) else {
            throw MachineFileVerificationFailure(
                code: "signature_invalid",
                message: "Machine file signature verification failed"
            )
        }
        #else
        throw MachineFileVerificationFailure(
            code: "crypto_unavailable",
            message: "Client-side verification crypto not available"
        )
        #endif
    }

    // MARK: - Decryption

    /// Open the AES-256-GCM payload with the device-bound derived key.
    ///
    /// The key is `SHA256(license_key || fingerprint)` with no separator, the
    /// nonce is 96 bits, the tag is 128 bits, and the AAD is empty — exactly
    /// what the issuing service produces.
    func decryptMachineFilePayload(
        _ enc: String,
        licenseKey: String,
        fingerprint: String
    ) throws -> Data {
        #if canImport(CryptoKit) || canImport(Crypto)
        let parts = enc.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3,
              parts[0].utf8.count <= MachineFileFormat.maxEncryptedTextBytes,
              parts[1].utf8.count <= 32,
              parts[2].utf8.count <= 32 else {
            throw MachineFileVerificationFailure(
                code: "invalid_machine_file",
                message: "Invalid encrypted machine-file format"
            )
        }
        guard let ciphertext = try? Base64URL.decode(String(parts[0])),
              let nonceBytes = try? Base64URL.decode(String(parts[1])),
              let tag = try? Base64URL.decode(String(parts[2])),
              ciphertext.count <= MachineFileFormat.maxCiphertextBytes,
              nonceBytes.count == MachineFileFormat.nonceBytes,
              tag.count == MachineFileFormat.tagBytes else {
            throw MachineFileVerificationFailure(
                code: "invalid_machine_file",
                message: "Invalid encrypted machine-file payload"
            )
        }

        var digest = SHA256()
        digest.update(data: Data(licenseKey.utf8))
        digest.update(data: Data(fingerprint.utf8))
        let key = SymmetricKey(data: Data(digest.finalize()))

        guard let nonce = try? AES.GCM.Nonce(data: nonceBytes),
              let sealedBox = try? AES.GCM.SealedBox(
                  nonce: nonce,
                  ciphertext: ciphertext,
                  tag: tag
              ),
              let plaintext = try? AES.GCM.open(sealedBox, using: key) else {
            throw MachineFileVerificationFailure(
                code: "decryption_failed",
                message: "Machine file could not be decrypted for this device"
            )
        }
        guard plaintext.count <= MachineFileFormat.maxCiphertextBytes else {
            throw MachineFileVerificationFailure(
                code: "invalid_machine_file_payload",
                message: "Decrypted machine-file payload is too large"
            )
        }
        return plaintext
        #else
        throw MachineFileVerificationFailure(
            code: "crypto_unavailable",
            message: "Client-side verification crypto not available"
        )
        #endif
    }

    // MARK: - Full Verification

    /// Verify and decrypt a machine file end to end.
    ///
    /// Ordering is deliberate and matches the other LicenseSeat SDKs: identity
    /// binding, then signature, then decryption, then claims. A caller that
    /// reaches the returned payload has already passed every check.
    func verifyMachineFileArtifact(
        _ machineFile: MachineFile,
        context: MachineFileVerificationContext
    ) throws -> MachineFilePayload {
        guard config.maxClockSkewMs.isFinite,
              config.maxClockSkewMs >= 0,
              config.maxClockSkewMs <= 86_400_000 else {
            throw MachineFileVerificationFailure(
                code: "invalid_configuration",
                message: "Clock skew configuration is invalid"
            )
        }
        try validateMachineFileBinding(machineFile, context: context)

        let envelope = try parseMachineFileEnvelope(machineFile.certificate)
        try verifyMachineFileSignature(envelope, publicKeyB64: context.publicKeyB64)

        let plaintext = try decryptMachineFilePayload(
            envelope.enc,
            licenseKey: context.licenseKey,
            fingerprint: context.fingerprint
        )
        let payload = try parseMachineFilePayload(plaintext)
        try validateMachineFileClaims(
            payload,
            envelopeKeyId: envelope.keyId,
            context: context
        )
        return payload
    }

    /// Reject an artifact whose own metadata already disagrees with the caller
    /// before spending any cryptographic work on it.
    private func validateMachineFileBinding(
        _ machineFile: MachineFile,
        context: MachineFileVerificationContext
    ) throws {
        guard machineFile.algorithm == MachineFileFormat.algorithm else {
            throw MachineFileVerificationFailure(
                code: "unsupported_algorithm",
                message: "Unsupported machine file algorithm"
            )
        }
        guard machineFile.certificate.utf8.count
            <= MachineFileFormat.maxCertificateBytes else {
            throw MachineFileVerificationFailure(
                code: "machine_file_too_large",
                message: "Machine file certificate is too large"
            )
        }
        if !machineFile.licenseKey.isEmpty,
           !MachineFileFormat.constantTimeEqual(
               machineFile.licenseKey,
               context.licenseKey
           ) {
            throw MachineFileVerificationFailure(
                code: "license_mismatch",
                message: "Machine file was issued for a different license"
            )
        }
        if !machineFile.fingerprint.isEmpty,
           !MachineFileFormat.constantTimeEqual(
               machineFile.fingerprint,
               context.fingerprint
           ) {
            throw MachineFileVerificationFailure(
                code: "fingerprint_mismatch",
                message: "Machine file was issued for a different device"
            )
        }
    }
}
