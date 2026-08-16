//
//  LicenseSeat+InputValidation.swift
//  LicenseSeatSDK
//
//  Bounds caller-controlled identities before serialization or persistence.
//

import Foundation

extension LicenseSeat {
    /// Validate caller-controlled identity fields before they reach a request
    /// body, cache namespace, or event. The server remains authoritative, but
    /// rejecting malformed local input avoids ambiguous cross-proxy parsing
    /// and unbounded serialization work.
    internal func validateRequestIdentity(
        productSlug: String,
        licenseKey: String
    ) throws {
        try validateProductSlug(productSlug)
        try validateLicenseKey(licenseKey)
    }

    /// The product slug is a route component on every product-scoped endpoint,
    /// so it is bounded and shape-checked even when no license key is involved.
    internal func validateProductSlug(_ productSlug: String) throws {
        guard productSlug.utf8.count <= 100,
              productSlug.range(
                  of: "^[a-z0-9]+(?:-[a-z0-9]+)*$",
                  options: .regularExpression
              ) != nil else {
            throw APIError.localFailure(
                code: "invalid_identity",
                message: "Invalid product or license identity"
            )
        }
    }

    internal func validateLicenseKey(_ licenseKey: String) throws {
        guard !licenseKey.isEmpty,
              licenseKey.utf8.count <= 512,
              licenseKey == licenseKey.trimmingCharacters(
                  in: .whitespacesAndNewlines
              ),
              licenseKey.unicodeScalars.allSatisfy({
                  $0.value > 31 && $0.value != 127
              }) else {
            throw APIError.localFailure(
                code: "invalid_identity",
                message: "Invalid product or license identity"
            )
        }
    }

    internal func validateFingerprint(
        _ fingerprint: String,
        allowLegacyShortValue: Bool
    ) throws {
        let minimumBytes = allowLegacyShortValue ? 1 : 8
        guard fingerprint.utf8.count >= minimumBytes,
              fingerprint.utf8.count <= 255,
              fingerprint == fingerprint.trimmingCharacters(
                  in: .whitespacesAndNewlines
              ),
              fingerprint.unicodeScalars.allSatisfy({
                  $0.value > 31 && $0.value != 127
              }) else {
            throw APIError.localFailure(
                code: "invalid_identity",
                message: "Invalid installation fingerprint"
            )
        }
    }
}
