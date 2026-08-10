import XCTest
@testable import LicenseSeat

final class PublicUtilityContractTests: LicenseSeatTestCase {
    func testLicenseSeatErrorDescriptionsCoverEveryStableCase() {
        let cases: [(LicenseSeatError, String)] = [
            (.noActiveLicense, "No active license found"),
            (.apiKeyRequired, "API key is required for this operation"),
            (.productSlugRequired, "Product slug is required for this operation"),
            (.invalidOfflineToken, "Invalid offline token structure"),
            (.invalidKeyId, "Invalid key ID"),
            (.invalidPublicKey, "Invalid public key"),
            (.cryptoUnavailable, "Cryptographic functionality unavailable on this platform"),
            (.networkError, "Network operation failed"),
            (.deviceIdentifierError, "Device identifier generation failed"),
            (.cacheError, "Cache operation failed"),
            (.validationFailed(reason: "denied"), "License validation failed: denied"),
            (.activationFailed(reason: "denied"), "License activation failed: denied")
        ]

        for (error, description) in cases {
            XCTAssertEqual(error.errorDescription, description)
        }
    }

    func testCSRFCompatibilityHelperNeverInventsACredential() {
        XCTAssertNil(CSRFToken.getToken())
        XCTAssertEqual(
            CSRFToken.addToHeaders(["Accept": "application/json"]),
            ["Accept": "application/json"]
        )
    }
}
