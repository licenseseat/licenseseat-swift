//
//  LicenseSeatFailureTests.swift
//  LicenseSeatSDKTests
//
//  #11: one exhaustive classification over every thrown error type.
//

import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import LicenseSeat

final class LicenseSeatFailureTests: LicenseSeatTestCase {
    private func api(_ status: Int, _ code: String? = nil) -> LicenseSeatFailure {
        LicenseSeatFailure(APIError(code: code, message: "server text with LS-SECRET-KEY", status: status))
    }

    func testServerErrorsAreClassifiedWithoutStringMatching() {
        let cases: [(LicenseSeatFailure, LicenseSeatFailure.Category)] = [
            (api(404, "license_not_found"), .invalidLicenseKey),
            (api(422, "invalid_license"), .licenseNotUsable),
            (api(422, "license_invalid"), .licenseNotUsable),
            (api(422, "license_invalid_general"), .licenseNotUsable),
            (api(422, "seat_limit_exceeded"), .seatLimitReached),
            (api(422, "device_limit_reached"), .seatLimitReached),
            (api(422, "revoked"), .licenseNotUsable),
            (api(422, "license_expired"), .licenseNotUsable),
            (api(422, "suspended"), .licenseNotUsable),
            (api(422, "DEVICE_NOT_ACTIVATED"), .licenseNotUsable),
            (api(403, "version_not_entitled"), .notEntitled),
            (api(403, "not_entitled"), .notEntitled),
            (api(422, "product_mismatch"), .notEntitled),
            (api(501, "floating_not_implemented"), .notEntitled),
            (api(410), .licenseNotUsable),
            (api(401, "unauthorized"), .unauthorized),
            (api(403, "forbidden"), .unauthorized),
            (api(429, "rate_limited"), .rateLimited),
            (api(503, "unavailable"), .server),
            (api(501), .server),
            (api(400, "parameter_missing"), .invalidRequest),
            (api(408, "request_timeout"), .network),
            (api(0), .network),
            (api(0, "invalid_base_url"), .configuration),
            (api(0, "invalid_identity"), .invalidRequest),
            (api(0, "invalid_response"), .invalidResponse),
            (api(0, "response_too_large"), .invalidResponse)
        ]
        for (failure, expected) in cases {
            XCTAssertEqual(failure.category, expected, "\(failure)")
        }
    }

    func testEverySurfaceTypeIsCovered() {
        XCTAssertEqual(LicenseSeatFailure(URLError(.notConnectedToInternet)).category, .network)
        XCTAssertEqual(LicenseSeatFailure(URLError(.timedOut)).category, .network)
        XCTAssertEqual(LicenseSeatFailure(URLError(.cancelled)), .cancelled)
        XCTAssertEqual(LicenseSeatFailure(CancellationError()), .cancelled)
        XCTAssertEqual(LicenseSeatFailure(LicenseSeatStoreError.notConfigured).category, .configuration)
        XCTAssertEqual(LicenseSeatFailure(StrictJSONError.invalidSyntax).category, .invalidResponse)
        let decoding = DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "bad"))
        XCTAssertEqual(LicenseSeatFailure(decoding).category, .invalidResponse)
        struct Foreign: Error {}
        XCTAssertEqual(LicenseSeatFailure(Foreign()).category, .unknown)

        let sdkCases: [(LicenseSeatError, LicenseSeatFailure.Category)] = [
            (.noActiveLicense, .notActivated),
            (.apiKeyRequired, .configuration),
            (.productSlugRequired, .configuration),
            (.cryptoUnavailable, .configuration),
            (.invalidOfflineToken, .invalidResponse),
            (.invalidKeyId, .invalidResponse),
            (.invalidPublicKey, .invalidResponse),
            (.networkError, .network),
            (.deviceIdentifierError, .deviceIdentity),
            (.cacheError, .storage),
            (.validationFailed(reason: "mismatch"), .invalidResponse),
            (.validationFailed(reason: "A newer validation request superseded this response."), .cancelled),
            (.validationFailed(reason: "A newer license-state operation superseded this validation request."), .cancelled),
            (.validationFailed(reason: "A newer heartbeat request superseded this response."), .cancelled),
            (.activationFailed(reason: "x"), .invalidResponse)
        ]
        for (error, expected) in sdkCases {
            XCTAssertEqual(LicenseSeatFailure(error).category, expected, "\(error)")
        }
    }

    func testWrappingIsIdempotentAndPreservesTheUnderlyingError() {
        let apiError = APIError(code: "revoked", message: "Revoked", status: 422)
        let failure = LicenseSeatFailure(apiError)
        XCTAssertEqual(LicenseSeatFailure(failure), failure)
        XCTAssertEqual(failure, .api(apiError))
        XCTAssertEqual(failure.code, "revoked")
    }

    func testRetryableAndTerminalAreConsistent() {
        XCTAssertTrue(api(503).isRetryable)
        XCTAssertFalse(api(501).isRetryable, "501 Not Implemented is not retried")
        XCTAssertTrue(api(429).isRetryable)
        XCTAssertTrue(LicenseSeatFailure(URLError(.notConnectedToInternet)).isRetryable)
        XCTAssertFalse(api(422, "revoked").isRetryable)
        XCTAssertFalse(api(401).isRetryable)

        XCTAssertTrue(api(422, "revoked").isTerminal)
        XCTAssertTrue(api(404, "license_not_found").isTerminal)
        XCTAssertTrue(api(422, "seat_limit_exceeded").isTerminal)
        XCTAssertTrue(LicenseSeatFailure(LicenseSeatError.noActiveLicense).isTerminal)
        XCTAssertFalse(api(503).isTerminal)
        XCTAssertFalse(LicenseSeatFailure(URLError(.timedOut)).isTerminal)
        XCTAssertFalse(LicenseSeatFailure(LicenseSeatError.deviceIdentifierError).isTerminal)

        let all: [LicenseSeatFailure] = [
            api(0), api(503), api(429), api(404, "license_not_found"), api(422, "seat_limit_exceeded"),
            api(422, "revoked"), api(403, "version_not_entitled"), .sdk(.noActiveLicense), api(401), api(400), api(0, "invalid_base_url"),
            .sdk(.deviceIdentifierError), .sdk(.cacheError), api(0, "invalid_response"), .cancelled,
            .other("x")
        ]
        XCTAssertEqual(Set(all.map(\.category)), Set(LicenseSeatFailure.Category.allCases))
        for failure in all {
            XCTAssertFalse(failure.isRetryable && failure.isTerminal, "\(failure)")
        }
    }

    func testUserMessagesNeverEchoServerText() {
        for code in ["revoked", "license_expired", "suspended", "device_not_activated", "other"] {
            let failure = api(422, code)
            XCTAssertFalse(failure.userMessage.contains("LS-SECRET-KEY"))
            XCTAssertFalse(failure.userMessage.isEmpty)
            XCTAssertEqual(failure.errorDescription, failure.userMessage)
        }
        XCTAssertEqual(api(422, "license_revoked").userMessage, "This license has been revoked.")
        XCTAssertEqual(api(422, "expired").userMessage, "This license has expired.")
        XCTAssertNotNil(LicenseSeatFailure(LicenseSeatError.deviceIdentifierError).recoverySuggestion)
        XCTAssertNil(LicenseSeatFailure.cancelled.recoverySuggestion)
        XCTAssertEqual(
            api(422, "device_not_activated").recoverySuggestion,
            "Enter your license key again to re-activate this device."
        )
        XCTAssertFalse(api(422, "license_invalid_general").userMessage.contains("typo"))
    }

    func testThrownErrorsFromTheSDKClassify() async throws {
        let sdk = await LicenseSeat(
            config: LicenseSeatConfig(storagePrefix: "failure_test_\(UUID().uuidString)_")
        )
        do {
            try await sdk.heartbeat()
            XCTFail("heartbeat without a product slug must throw")
        } catch {
            XCTAssertEqual(LicenseSeatFailure(error).category, .configuration)
        }
    }
}
