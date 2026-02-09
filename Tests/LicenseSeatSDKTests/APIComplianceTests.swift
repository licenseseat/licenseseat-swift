///
/// APIComplianceTests.swift
/// LicenseSeatSDKTests
///
/// Comprehensive tests for API v1 compliance.
/// These tests verify that the SDK correctly decodes/encodes the new API response formats.
///

import XCTest
import Foundation
@testable import LicenseSeat

// MARK: - ActivationResponse Decoding Tests

/// Tests for ActivationResponse decoding (new v1 API format)
final class ActivationResponseDecodingTests: XCTestCase {

    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    /// Full activation response with nested license
    func testDecodesFullActivationResponse() throws {
        let json = """
        {
            "object": "activation",
            "id": "act-12345-uuid",
            "device_id": "device-abc-123",
            "device_name": "John's MacBook Pro",
            "license_key": "LS-PRO-2025",
            "activated_at": "2025-01-15T10:00:00Z",
            "deactivated_at": null,
            "ip_address": "192.168.1.1",
            "metadata": {"region": "us-west"},
            "license": {
                "object": "license",
                "key": "LS-PRO-2025",
                "status": "active",
                "starts_at": "2025-01-01T00:00:00Z",
                "expires_at": "2026-01-01T00:00:00Z",
                "mode": "hardware_locked",
                "plan_key": "pro_annual",
                "seat_limit": 5,
                "active_seats": 1,
                "active_entitlements": [
                    {"key": "pro-features", "expires_at": null, "metadata": null}
                ],
                "metadata": null,
                "product": {"slug": "my-app", "name": "My App"}
            }
        }
        """

        let result = try decoder.decode(ActivationResponse.self, from: Data(json.utf8))

        XCTAssertEqual(result.object, "activation")
        XCTAssertEqual(result.id, "act-12345-uuid")
        XCTAssertEqual(result.deviceId, "device-abc-123")
        XCTAssertEqual(result.deviceName, "John's MacBook Pro")
        XCTAssertEqual(result.licenseKey, "LS-PRO-2025")
        XCTAssertNotNil(result.activatedAt)
        XCTAssertNil(result.deactivatedAt)
        XCTAssertEqual(result.ipAddress, "192.168.1.1")
        XCTAssertNotNil(result.metadata)

        // Verify nested license
        XCTAssertEqual(result.license.object, "license")
        XCTAssertEqual(result.license.key, "LS-PRO-2025")
        XCTAssertEqual(result.license.status, "active")
        XCTAssertEqual(result.license.mode, "hardware_locked")
        XCTAssertEqual(result.license.seatLimit, 5)
        XCTAssertEqual(result.license.activeSeats, 1)
        XCTAssertEqual(result.license.activeEntitlements.count, 1)
        XCTAssertEqual(result.license.product.slug, "my-app")
    }

    /// Minimal activation response
    func testDecodesMinimalActivationResponse() throws {
        let json = """
        {
            "object": "activation",
            "id": "act-1-uuid",
            "device_id": "dev-1",
            "device_name": null,
            "license_key": "KEY-1",
            "activated_at": "2025-01-15T10:00:00Z",
            "deactivated_at": null,
            "ip_address": null,
            "metadata": null,
            "license": {
                "object": "license",
                "key": "KEY-1",
                "status": "active",
                "starts_at": null,
                "expires_at": null,
                "mode": "unlimited",
                "plan_key": "free",
                "seat_limit": null,
                "active_seats": 0,
                "active_entitlements": [],
                "metadata": null,
                "product": {"slug": "app", "name": "App"}
            }
        }
        """

        let result = try decoder.decode(ActivationResponse.self, from: Data(json.utf8))

        XCTAssertEqual(result.id, "act-1-uuid")
        XCTAssertNil(result.deviceName)
        XCTAssertNil(result.ipAddress)
        XCTAssertNil(result.metadata)
        XCTAssertNil(result.license.seatLimit)
        XCTAssertTrue(result.license.activeEntitlements.isEmpty)
    }
}

// MARK: - DeactivationResponse Decoding Tests

final class DeactivationResponseDecodingTests: XCTestCase {

    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    func testDecodesDeactivationResponse() throws {
        let json = """
        {
            "object": "deactivation",
            "activation_id": "act-12345-uuid",
            "deactivated_at": "2025-01-20T15:30:00Z"
        }
        """

        let result = try decoder.decode(DeactivationResponse.self, from: Data(json.utf8))

        XCTAssertEqual(result.object, "deactivation")
        XCTAssertEqual(result.activationId, "act-12345-uuid")
        XCTAssertNotNil(result.deactivatedAt)
    }
}

// MARK: - ValidationResponse Decoding Tests

/// Tests for ValidationResponse decoding (new v1 API format)
final class ValidationResponseDecodingTests: XCTestCase {

    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    /// Valid validation response with nested license
    func testDecodesValidValidationResponse() throws {
        let json = """
        {
            "object": "validation_result",
            "valid": true,
            "code": null,
            "message": null,
            "warnings": [],
            "license": {
                "object": "license",
                "key": "TEST-KEY",
                "status": "active",
                "starts_at": null,
                "expires_at": "2026-12-31T23:59:59Z",
                "mode": "hardware_locked",
                "plan_key": "pro",
                "seat_limit": 5,
                "active_seats": 2,
                "active_entitlements": [
                    {"key": "feature-a", "expires_at": null, "metadata": null},
                    {"key": "feature-b", "expires_at": "2025-12-31T23:59:59Z", "metadata": null}
                ],
                "metadata": null,
                "product": {"slug": "my-app", "name": "My App"}
            },
            "activation": null
        }
        """

        let result = try decoder.decode(ValidationResponse.self, from: Data(json.utf8))

        XCTAssertEqual(result.object, "validation_result")
        XCTAssertTrue(result.valid)
        XCTAssertNil(result.code)
        XCTAssertNil(result.message)
        XCTAssertEqual(result.license.key, "TEST-KEY")
        XCTAssertEqual(result.license.activeEntitlements.count, 2)
        XCTAssertEqual(result.license.activeEntitlements[0].key, "feature-a")
        XCTAssertNil(result.activation)
    }

    /// Invalid validation response with code and message
    func testDecodesInvalidValidationResponse() throws {
        let json = """
        {
            "object": "validation_result",
            "valid": false,
            "code": "license_expired",
            "message": "License has expired",
            "warnings": null,
            "license": {
                "object": "license",
                "key": "EXPIRED-KEY",
                "status": "expired",
                "starts_at": "2024-01-01T00:00:00Z",
                "expires_at": "2024-12-31T23:59:59Z",
                "mode": "hardware_locked",
                "plan_key": "pro",
                "seat_limit": 1,
                "active_seats": 0,
                "active_entitlements": [],
                "metadata": null,
                "product": {"slug": "app", "name": "App"}
            },
            "activation": null
        }
        """

        let result = try decoder.decode(ValidationResponse.self, from: Data(json.utf8))

        XCTAssertFalse(result.valid)
        XCTAssertEqual(result.code, "license_expired")
        XCTAssertEqual(result.message, "License has expired")
        XCTAssertEqual(result.license.status, "expired")
    }

    /// Validation response with activation included (when device_id was provided)
    func testDecodesValidationWithActivation() throws {
        let json = """
        {
            "object": "validation_result",
            "valid": true,
            "code": null,
            "message": null,
            "warnings": [{"code": "expiring_soon", "message": "License expires in 7 days"}],
            "license": {
                "object": "license",
                "key": "TEST-KEY",
                "status": "active",
                "starts_at": null,
                "expires_at": "2025-01-22T00:00:00Z",
                "mode": "hardware_locked",
                "plan_key": "pro",
                "seat_limit": 1,
                "active_seats": 1,
                "active_entitlements": [],
                "metadata": null,
                "product": {"slug": "app", "name": "App"}
            },
            "activation": {
                "id": "act-999-uuid",
                "device_id": "my-device",
                "device_name": "My Mac",
                "license_key": "TEST-KEY",
                "activated_at": "2025-01-01T00:00:00Z",
                "deactivated_at": null,
                "ip_address": "10.0.0.1",
                "metadata": null
            }
        }
        """

        let result = try decoder.decode(ValidationResponse.self, from: Data(json.utf8))

        XCTAssertTrue(result.valid)
        XCTAssertEqual(result.warnings?.count, 1)
        XCTAssertEqual(result.warnings?[0].code, "expiring_soon")
        XCTAssertNotNil(result.activation)
        XCTAssertEqual(result.activation?.id, "act-999-uuid")
        XCTAssertEqual(result.activation?.deviceId, "my-device")
    }
}

// MARK: - OfflineTokenResponse Decoding Tests

final class OfflineTokenResponseDecodingTests: XCTestCase {

    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    func testDecodesOfflineTokenResponse() throws {
        let json = """
        {
            "object": "offline_token",
            "token": {
                "schema_version": 1,
                "license_key": "LS-PRO-2025",
                "product_slug": "my-app",
                "plan_key": "pro_annual",
                "mode": "hardware_locked",
                "seat_limit": 5,
                "device_id": "device-abc-123",
                "iat": 1737504000,
                "exp": 1740096000,
                "nbf": 1737504000,
                "license_expires_at": 1768816800,
                "kid": "org-xxx-offline-v1",
                "entitlements": [
                    {"key": "pro-features", "expires_at": null}
                ],
                "metadata": null
            },
            "signature": {
                "algorithm": "Ed25519",
                "key_id": "org-xxx-offline-v1",
                "value": "base64-signature-value"
            },
            "canonical": "{\\"device_id\\":\\"device-abc-123\\",\\"exp\\":1740096000}"
        }
        """

        let result = try decoder.decode(OfflineTokenResponse.self, from: Data(json.utf8))

        XCTAssertEqual(result.object, "offline_token")
        XCTAssertEqual(result.token.schemaVersion, 1)
        XCTAssertEqual(result.token.licenseKey, "LS-PRO-2025")
        XCTAssertEqual(result.token.productSlug, "my-app")
        XCTAssertEqual(result.token.mode, "hardware_locked")
        XCTAssertEqual(result.token.seatLimit, 5)
        XCTAssertEqual(result.token.deviceId, "device-abc-123")
        XCTAssertEqual(result.token.iat, 1737504000)
        XCTAssertEqual(result.token.exp, 1740096000)
        XCTAssertEqual(result.token.kid, "org-xxx-offline-v1")
        XCTAssertEqual(result.token.entitlements.count, 1)
        XCTAssertEqual(result.token.entitlements[0].key, "pro-features")

        XCTAssertEqual(result.signature.algorithm, "Ed25519")
        XCTAssertEqual(result.signature.keyId, "org-xxx-offline-v1")
        XCTAssertEqual(result.signature.value, "base64-signature-value")
        XCTAssertFalse(result.canonical.isEmpty)
    }
}

// MARK: - SigningKeyResponse Decoding Tests

final class SigningKeyResponseDecodingTests: XCTestCase {

    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    func testDecodesSigningKeyResponse() throws {
        let json = """
        {
            "object": "signing_key",
            "key_id": "org-xxx-offline-v1",
            "algorithm": "Ed25519",
            "public_key": "base64url-encoded-public-key",
            "created_at": "2025-01-01T00:00:00Z",
            "status": "active"
        }
        """

        let result = try decoder.decode(SigningKeyResponse.self, from: Data(json.utf8))

        XCTAssertEqual(result.object, "signing_key")
        XCTAssertEqual(result.keyId, "org-xxx-offline-v1")
        XCTAssertEqual(result.algorithm, "Ed25519")
        XCTAssertEqual(result.publicKey, "base64url-encoded-public-key")
        XCTAssertNotNil(result.createdAt)
        XCTAssertEqual(result.status, "active")
    }
}

// MARK: - HealthResponse Decoding Tests

final class HealthResponseDecodingTests: XCTestCase {

    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    func testDecodesHealthResponse() throws {
        let json = """
        {
            "object": "health",
            "status": "healthy",
            "api_version": "2026-01-21",
            "timestamp": "2025-01-15T10:00:00Z"
        }
        """

        let result = try decoder.decode(HealthResponse.self, from: Data(json.utf8))

        XCTAssertEqual(result.object, "health")
        XCTAssertEqual(result.status, "healthy")
        XCTAssertEqual(result.apiVersion, "2026-01-21")
        XCTAssertNotNil(result.timestamp)
    }
}

// MARK: - Entitlement Decoding Tests

final class EntitlementDecodingTests: XCTestCase {

    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    func testDecodesFullEntitlement() throws {
        let json = """
        {
            "key": "premium",
            "expires_at": "2026-12-31T23:59:59Z",
            "metadata": {"tier": "gold", "seats": 5}
        }
        """

        let entitlement = try decoder.decode(Entitlement.self, from: Data(json.utf8))

        XCTAssertEqual(entitlement.key, "premium")
        XCTAssertNotNil(entitlement.expiresAt)
        XCTAssertNotNil(entitlement.metadata)
        XCTAssertEqual(entitlement.metadata?["tier"]?.value as? String, "gold")
        XCTAssertEqual(entitlement.metadata?["seats"]?.value as? Int, 5)
    }

    func testDecodesMinimalEntitlement() throws {
        let json = """
        {"key": "basic"}
        """

        let entitlement = try decoder.decode(Entitlement.self, from: Data(json.utf8))

        XCTAssertEqual(entitlement.key, "basic")
        XCTAssertNil(entitlement.expiresAt)
        XCTAssertNil(entitlement.metadata)
    }

    func testDecodesEntitlementWithNulls() throws {
        let json = """
        {"key": "standard", "expires_at": null, "metadata": null}
        """

        let entitlement = try decoder.decode(Entitlement.self, from: Data(json.utf8))

        XCTAssertEqual(entitlement.key, "standard")
        XCTAssertNil(entitlement.expiresAt)
        XCTAssertNil(entitlement.metadata)
    }
}

// MARK: - Configuration Tests

final class ConfigurationTests: XCTestCase {

    func testProductionAPIBaseURLConstant() {
        XCTAssertEqual(LicenseSeatConfig.productionAPIBaseURL, "https://licenseseat.com/api/v1")
    }

    func testDefaultConfigUsesProductionURL() {
        let config = LicenseSeatConfig.default
        XCTAssertEqual(config.apiBaseUrl, LicenseSeatConfig.productionAPIBaseURL)
        XCTAssertEqual(config.apiBaseUrl, "https://licenseseat.com/api/v1")
    }

    func testInitWithoutParametersUsesProductionURL() {
        let config = LicenseSeatConfig()
        XCTAssertEqual(config.apiBaseUrl, LicenseSeatConfig.productionAPIBaseURL)
    }

    func testCustomURLOverridesDefault() {
        let config = LicenseSeatConfig(apiBaseUrl: "https://custom.api.com")
        XCTAssertEqual(config.apiBaseUrl, "https://custom.api.com")
    }

    func testDefaultConfigValues() {
        let config = LicenseSeatConfig.default

        XCTAssertNil(config.apiKey)
        XCTAssertNil(config.productSlug)
        XCTAssertEqual(config.storagePrefix, "licenseseat_")
        XCTAssertNil(config.deviceIdentifier)
        XCTAssertEqual(config.autoValidateInterval, 3600) // 1 hour
        XCTAssertEqual(config.heartbeatInterval, 300) // 5 minutes
        XCTAssertEqual(config.networkRecheckInterval, 30)
        XCTAssertEqual(config.maxRetries, 3)
        XCTAssertEqual(config.retryDelay, 1)
        XCTAssertFalse(config.debug)
        XCTAssertEqual(config.offlineTokenRefreshInterval, 259200) // 72 hours
        XCTAssertEqual(config.maxOfflineDays, 0)
        XCTAssertEqual(config.maxClockSkewMs, 300000) // 5 minutes
        XCTAssertEqual(config.offlineFallbackMode, .networkOnly)
    }

    func testProductSlugConfiguration() {
        var config = LicenseSeatConfig()
        XCTAssertNil(config.productSlug)

        config.productSlug = "my-app"
        XCTAssertEqual(config.productSlug, "my-app")
    }
}

// MARK: - APIError Tests

final class APIErrorDecodingTests: XCTestCase {

    func testParsesNewErrorFormat() {
        let errorJSON: [String: Any] = [
            "error": [
                "code": "license_not_found",
                "message": "License key not found",
                "details": ["key": "INVALID-KEY"]
            ]
        ]

        let error = APIError(from: errorJSON, status: 404)

        XCTAssertEqual(error.code, "license_not_found")
        XCTAssertEqual(error.message, "License key not found")
        XCTAssertEqual(error.status, 404)
    }

    func testParsesErrorWithoutDetails() {
        let errorJSON: [String: Any] = [
            "error": [
                "code": "expired",
                "message": "License expired"
            ]
        ]

        let error = APIError(from: errorJSON, status: 422)

        XCTAssertEqual(error.code, "expired")
        XCTAssertEqual(error.message, "License expired")
        XCTAssertNil(error.details)
    }

    func testFallbackForNonStandardError() {
        let errorJSON: [String: Any] = [
            "message": "Something went wrong"
        ]

        let error = APIError(from: errorJSON, status: 500)

        XCTAssertNil(error.code)
        XCTAssertEqual(error.message, "Something went wrong")
    }

    func testErrorClassification() {
        let networkError = APIError(message: "Timeout", status: 0)
        XCTAssertTrue(networkError.isNetworkError)
        XCTAssertFalse(networkError.isServerError)

        let serverError = APIError(message: "Internal error", status: 500)
        XCTAssertTrue(serverError.isServerError)
        XCTAssertFalse(serverError.isClientError)

        let clientError = APIError(message: "Bad request", status: 400)
        XCTAssertTrue(clientError.isClientError)
        XCTAssertFalse(clientError.isServerError)

        let authError = APIError(message: "Unauthorized", status: 401)
        XCTAssertTrue(authError.isAuthError)

        let terminalError = APIError(code: "revoked", message: "License revoked", status: 422)
        XCTAssertTrue(terminalError.isLicenseTerminalError)

        let retryableError = APIError(message: "Service unavailable", status: 503)
        XCTAssertTrue(retryableError.isRetryable)

        let nonRetryableError = APIError(message: "Not found", status: 404)
        XCTAssertFalse(nonRetryableError.isRetryable)
    }
}
