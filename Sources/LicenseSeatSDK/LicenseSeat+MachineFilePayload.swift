//
//  LicenseSeat+MachineFilePayload.swift
//  LicenseSeatSDK
//
//  Decoding the decrypted machine-file document into a typed payload.
//

import Foundation

extension LicenseSeat {

    /// Parse the decrypted JSON:API document into a typed payload.
    ///
    /// Decryption proves authenticity; this proves shape. Anything the issuer
    /// would never emit is rejected here rather than being carried forward as
    /// a default.
    func parseMachineFilePayload(_ plaintext: Data) throws -> MachineFilePayload {
        guard (try? StrictJSON.validate(plaintext, limits: .signedPayload)) != nil,
              let object = try? JSONSerialization.jsonObject(with: plaintext),
              let root = object as? [String: Any] else {
            throw MachineFileVerificationFailure(
                code: "invalid_machine_file_payload",
                message: "Decrypted machine-file payload is not a JSON object"
            )
        }
        guard let meta = root["meta"] as? [String: Any] else {
            throw MachineFileVerificationFailure(
                code: "invalid_machine_file_payload",
                message: "Machine-file metadata is missing"
            )
        }
        guard let data = root["data"] as? [String: Any] else {
            throw MachineFileVerificationFailure(
                code: "invalid_machine_file_payload",
                message: "Machine data is missing"
            )
        }
        guard data["type"] as? String == "machines",
              let attributes = data["attributes"] as? [String: Any],
              let relationships = data["relationships"] as? [String: Any] else {
            throw MachineFileVerificationFailure(
                code: "invalid_machine_file_payload",
                message: "Machine data is invalid"
            )
        }

        let relationshipLicenseKey = try machineRelationshipIdentifier(
            relationships,
            name: "license",
            expectedType: "licenses"
        )
        let productSlug = try machineRelationshipIdentifier(
            relationships,
            name: "product",
            expectedType: "products"
        )
        let licenseKey = meta["lic"] as? String ?? ""
        guard MachineFileFormat.constantTimeEqual(relationshipLicenseKey, licenseKey) else {
            throw MachineFileVerificationFailure(
                code: "license_mismatch",
                message: "Machine relationship license does not match the payload"
            )
        }

        return MachineFilePayload(
            schemaVersion: meta["schema_version"] as? Int ?? 0,
            issued: meta["issued"] as? String ?? "",
            iat: meta["iat"] as? Int ?? 0,
            expiry: meta["expiry"] as? String ?? "",
            exp: meta["exp"] as? Int ?? 0,
            nbf: meta["nbf"] as? Int ?? 0,
            ttl: meta["ttl"] as? Int ?? 0,
            gracePeriod: meta["grace_period"] as? Int ?? 0,
            licenseKey: licenseKey,
            productSlug: productSlug,
            licenseExpiresAt: try machineLicenseExpiry(meta["license_exp"]),
            keyId: meta["kid"] as? String ?? "",
            sdkVersion: meta["sdk_version"] as? String,
            machineId: data["id"] as? String ?? "",
            fingerprint: attributes["fingerprint"] as? String ?? "",
            fingerprintComponents: try machineFingerprintComponents(
                attributes["fingerprint_components"]
            ),
            deviceName: attributes["name"] as? String ?? "",
            platform: attributes["platform"] as? String ?? "",
            createdAt: try optionalMachineTimestamp(
                attributes["created"],
                field: "machine creation"
            ),
            metadata: (attributes["metadata"] as? [String: Any])?
                .mapValues(AnyCodable.init) ?? [:],
            license: try parseIncludedMachineLicense(
                root["included"],
                relationshipProductSlug: productSlug
            )
        )
    }

    private func machineLicenseExpiry(_ value: Any?) throws -> Int? {
        switch value {
        case nil, is NSNull:
            return nil
        case let value as Int:
            return value
        default:
            throw MachineFileVerificationFailure(
                code: "invalid_machine_file_payload",
                message: "License expiry claim is invalid"
            )
        }
    }

    private func machineRelationshipIdentifier(
        _ relationships: [String: Any],
        name: String,
        expectedType: String
    ) throws -> String {
        guard let wrapper = relationships[name] as? [String: Any],
              let relationship = wrapper["data"] as? [String: Any],
              relationship["type"] as? String == expectedType,
              let identifier = relationship["id"] as? String,
              !identifier.isEmpty else {
            throw MachineFileVerificationFailure(
                code: "invalid_machine_file_payload",
                message: "Machine \(name) relationship is invalid"
            )
        }
        return identifier
    }

    private func machineFingerprintComponents(
        _ value: Any?
    ) throws -> [String: String] {
        switch value {
        case nil, is NSNull:
            return [:]
        case let map as [String: Any]:
            var components: [String: String] = [:]
            for (key, item) in map {
                guard let text = item as? String else {
                    throw MachineFileVerificationFailure(
                        code: "invalid_machine_file_payload",
                        message: "Fingerprint components are invalid"
                    )
                }
                components[key] = text
            }
            return components
        default:
            throw MachineFileVerificationFailure(
                code: "invalid_machine_file_payload",
                message: "Fingerprint components are invalid"
            )
        }
    }

    func optionalMachineTimestamp(_ value: Any?, field: String) throws -> Date? {
        switch value {
        case nil, is NSNull:
            return nil
        case let text as String:
            guard let date = ISO8601Timestamp.parse(text) else {
                throw MachineFileVerificationFailure(
                    code: "invalid_machine_file_payload",
                    message: "Invalid \(field) timestamp"
                )
            }
            return date
        default:
            throw MachineFileVerificationFailure(
                code: "invalid_machine_file_payload",
                message: "Invalid \(field) timestamp"
            )
        }
    }

    // MARK: - Included License

    /// Decode the optional embedded license object.
    ///
    /// The issuer includes at most one, and its identity must agree with both
    /// the machine relationships and its own attributes.
    private func parseIncludedMachineLicense(
        _ included: Any?,
        relationshipProductSlug: String
    ) throws -> LicenseResponse? {
        guard let entry = try singleIncludedLicense(included) else { return nil }
        guard let attributes = entry["attributes"] as? [String: Any] else {
            throw MachineFileVerificationFailure(
                code: "included_license_mismatch",
                message: "Included license is invalid"
            )
        }
        let string = { (key: String) -> String in attributes[key] as? String ?? "" }

        let identifier = entry["id"] as? String ?? ""
        let key = string("key").isEmpty ? identifier : string("key")
        guard !identifier.isEmpty,
              !key.isEmpty,
              MachineFileFormat.constantTimeEqual(identifier, key) else {
            throw MachineFileVerificationFailure(
                code: "included_license_mismatch",
                message: "Included license identity does not match"
            )
        }

        let productSlug = string("product_slug").isEmpty
            ? relationshipProductSlug
            : string("product_slug")
        guard relationshipProductSlug.isEmpty
            || productSlug.isEmpty
            || MachineFileFormat.constantTimeEqual(relationshipProductSlug, productSlug) else {
            throw MachineFileVerificationFailure(
                code: "product_mismatch",
                message: "Included license product does not match the machine relationship"
            )
        }
        guard !productSlug.isEmpty,
              !string("status").isEmpty,
              !string("mode").isEmpty,
              !string("plan_key").isEmpty else {
            throw MachineFileVerificationFailure(
                code: "included_license_mismatch",
                message: "Included license is incomplete"
            )
        }

        return LicenseResponse(
            object: "license",
            key: key,
            status: string("status"),
            startsAt: try optionalMachineTimestamp(
                attributes["starts_at"],
                field: "license start"
            ),
            expiresAt: try optionalMachineTimestamp(
                attributes["ends_at"],
                field: "license expiry"
            ),
            mode: string("mode"),
            planKey: string("plan_key"),
            seatLimit: try includedSeatLimit(attributes["seat_limit"]),
            activeSeats: 0,
            activeEntitlements: try includedEntitlements(attributes["entitlements"]),
            metadata: (attributes["metadata"] as? [String: Any])?
                .mapValues(AnyCodable.init),
            product: Product(slug: productSlug, name: productSlug)
        )
    }

    private func singleIncludedLicense(_ included: Any?) throws -> [String: Any]? {
        let entries: [Any]
        switch included {
        case nil, is NSNull:
            entries = []
        case let array as [Any]:
            entries = array
        default:
            throw MachineFileVerificationFailure(
                code: "included_license_mismatch",
                message: "Included machine-file data is invalid"
            )
        }

        let licenses = entries.compactMap { $0 as? [String: Any] }
            .filter { $0["type"] as? String == "licenses" }
        guard licenses.count <= 1 else {
            throw MachineFileVerificationFailure(
                code: "included_license_mismatch",
                message: "Machine file contains more than one included license"
            )
        }
        return licenses.first
    }

    private func includedSeatLimit(_ value: Any?) throws -> Int? {
        switch value {
        case nil, is NSNull:
            return nil
        case let value as Int where value >= 0:
            return value
        default:
            throw MachineFileVerificationFailure(
                code: "included_license_mismatch",
                message: "Included license seat limit is invalid"
            )
        }
    }

    private func includedEntitlements(_ value: Any?) throws -> [Entitlement] {
        let items: [Any]
        switch value {
        case nil, is NSNull:
            items = []
        case let array as [Any]:
            items = array
        default:
            throw MachineFileVerificationFailure(
                code: "included_license_mismatch",
                message: "Included entitlements are invalid"
            )
        }

        return try items.map { item in
            guard let entitlement = item as? [String: Any],
                  let entitlementKey = entitlement["key"] as? String,
                  !entitlementKey.isEmpty else {
                throw MachineFileVerificationFailure(
                    code: "included_license_mismatch",
                    message: "Included entitlement is invalid"
                )
            }
            return Entitlement(
                key: entitlementKey,
                expiresAt: try optionalMachineTimestamp(
                    entitlement["expires_at"],
                    field: "entitlement expiry"
                ),
                metadata: nil
            )
        }
    }
}
