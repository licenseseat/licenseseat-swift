//
//  LicenseSeatFailure.swift
//  LicenseSeatSDK
//
//  One umbrella over every error a throwing SDK call can surface (#11).
//

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Any error thrown by the SDK, classified.
///
/// Throwing SDK calls keep throwing their existing types (``APIError``,
/// ``LicenseSeatError``, `URLError`, `CancellationError`, …), so existing
/// `catch` ladders are unaffected. Wrap whatever you caught to get one
/// exhaustive classification instead:
///
/// ```swift
/// do {
///     try await LicenseSeat.shared.activate(licenseKey: key)
/// } catch {
///     let failure = LicenseSeatFailure(error)
///     switch failure.category {
///     case .invalidLicenseKey: showKeyFieldError(failure.userMessage)
///     case .seatLimitReached:  offerDeviceManagement()
///     case .network where failure.isRetryable: showRetry(failure.userMessage)
///     default: showAlert(failure.userMessage, failure.recoverySuggestion)
///     }
/// }
/// ```
public enum LicenseSeatFailure: Error, Equatable, Sendable {
    /// The LicenseSeat API answered with an error, or the SDK rejected a
    /// request or response it built or received (``APIError/status`` `0`).
    case api(APIError)
    /// A local SDK precondition or verification failed.
    case sdk(LicenseSeatError)
    /// No usable HTTP exchange took place (offline, DNS, TLS, timeout, …).
    case transport(URLError)
    /// The operation was cancelled or superseded by a newer one.
    case cancelled
    /// A response could not be decoded. Carries the decoder's description.
    case decoding(String)
    /// The shared store was used before `configure(…)`.
    case notConfigured
    /// Anything else. Carries the error's description.
    case other(String)

    /// What kind of problem this is, independent of which type carried it.
    public enum Category: String, Equatable, Sendable, CaseIterable {
        /// The device could not reach the service.
        case network
        /// The service failed (5xx).
        case server
        /// Too many requests (429).
        case rateLimited
        /// The license key does not exist or is malformed.
        case invalidLicenseKey
        /// Every seat of the license is in use.
        case seatLimitReached
        /// The license exists but cannot be used: revoked, expired,
        /// suspended, not active, or this device's activation is gone.
        case licenseNotUsable
        /// Nothing is activated on this device.
        case notActivated
        /// The API key is missing, invalid, or lacks the required scope.
        case unauthorized
        /// The request was rejected as malformed (other 4xx, or local input
        /// validation).
        case invalidRequest
        /// The SDK is misconfigured (missing API key or product slug, bad
        /// base URL, unsupported platform crypto, …).
        case configuration
        /// The installation identity could not be read, typically because the
        /// Keychain is locked.
        case deviceIdentity
        /// Protected local storage could not be written.
        case storage
        /// A response was malformed, did not match the request, or failed
        /// verification.
        case invalidResponse
        /// Cancelled or superseded by a newer operation.
        case cancelled
        /// Not classifiable.
        case unknown
    }

    // MARK: - Classification

    /// Classify any error. Already-classified failures pass through.
    public init(_ error: any Error) {
        switch error {
        case let failure as LicenseSeatFailure:
            self = failure
        case let apiError as APIError:
            self = .api(apiError)
        case let sdkError as LicenseSeatError:
            self = .sdk(sdkError)
        case let urlError as URLError:
            self = urlError.code == .cancelled ? .cancelled : .transport(urlError)
        case is CancellationError:
            self = .cancelled
        case let decodingError as DecodingError:
            self = .decoding(String(describing: decodingError))
        case is StrictJSONError:
            self = .decoding(String(describing: error))
        case is LicenseSeatStoreError:
            self = .notConfigured
        default:
            self = .other(String(describing: error))
        }
    }

    public var category: Category {
        switch self {
        case .api(let error):
            return Self.category(of: error)
        case .sdk(let error):
            return Self.category(of: error)
        case .transport:
            return .network
        case .cancelled:
            return .cancelled
        case .decoding:
            return .invalidResponse
        case .notConfigured:
            return .configuration
        case .other:
            return .unknown
        }
    }

    /// The server's or SDK's machine-readable code, when there is one.
    public var code: String? {
        switch self {
        case .api(let error):
            return error.code
        case .transport(let error):
            return "url_error_\(error.code.rawValue)"
        case .sdk, .cancelled, .decoding, .notConfigured, .other:
            return nil
        }
    }

    /// Whether repeating the same call later may succeed without anyone
    /// changing anything (connectivity, server failure, rate limit).
    public var isRetryable: Bool {
        switch category {
        case .network, .rateLimited:
            return true
        case .server:
            if case .api(let error) = self { return error.isRetryable }
            return true
        default:
            return false
        }
    }

    /// Whether the license itself cannot be used as things stand: retrying
    /// will not help until the customer or the vendor acts (a different key,
    /// a freed seat, a renewed or reinstated license, a new activation).
    public var isTerminal: Bool {
        switch category {
        case .invalidLicenseKey, .seatLimitReached, .licenseNotUsable, .notActivated:
            return true
        default:
            return false
        }
    }

    /// A short explanation that is safe to show to the end user. It never
    /// contains keys, fingerprints, URLs, or server-provided text.
    public var userMessage: String {
        switch category {
        case .network:
            return "Couldn't reach the license server. Check your internet connection."
        case .server:
            return "The license server is having trouble right now."
        case .rateLimited:
            return "Too many license requests. Please wait a moment."
        case .invalidLicenseKey:
            return "That license key isn't valid."
        case .seatLimitReached:
            return "This license is already in use on the maximum number of devices."
        case .licenseNotUsable:
            return licenseNotUsableMessage
        case .notActivated:
            return "No license is activated on this device."
        case .unauthorized:
            return "The app couldn't authenticate with the license server."
        case .invalidRequest:
            return "The license request was rejected."
        case .configuration:
            return "Licensing isn't configured correctly in this app."
        case .deviceIdentity:
            return "This device's identity couldn't be read. Your keychain may be locked."
        case .storage:
            return "The license couldn't be saved on this device."
        case .invalidResponse:
            return "The license server sent an unexpected response."
        case .cancelled:
            return "The license operation was cancelled."
        case .unknown:
            return "Something went wrong while checking your license."
        }
    }

    /// What the user (or, for configuration problems, the developer) can do.
    public var recoverySuggestion: String? {
        switch category {
        case .network:
            return "Connect to the internet and try again."
        case .server, .rateLimited, .invalidResponse:
            return "Try again in a few minutes."
        case .invalidLicenseKey:
            return "Check the key for typos, or copy it again from your purchase email."
        case .seatLimitReached:
            return "Deactivate the license on another device, then try again."
        case .licenseNotUsable:
            return "Contact support or renew your license."
        case .notActivated:
            return "Enter your license key to activate this device."
        case .unauthorized, .configuration, .invalidRequest:
            return "Contact the app's developer."
        case .deviceIdentity:
            return "Unlock your login keychain (or log out and back in), then try again."
        case .storage:
            return "Make sure the disk isn't full, then try again."
        case .cancelled, .unknown:
            return nil
        }
    }

    // MARK: - Private

    private var licenseNotUsableMessage: String {
        let code: String?
        switch self {
        case .api(let error):
            code = error.code?.lowercased()
        default:
            code = nil
        }
        switch code {
        case "revoked", "license_revoked":
            return "This license has been revoked."
        case "expired", "license_expired":
            return "This license has expired."
        case "suspended", "license_suspended":
            return "This license is suspended."
        case "device_not_activated", "activation_not_found":
            return "This device is no longer activated for the license."
        default:
            return "This license can't be used right now."
        }
    }

    private static let configurationCodes: Set<String> = [
        "invalid_base_url", "invalid_endpoint_path", "invalid_headers",
        "invalid_retry_configuration", "invalid_configuration", "crypto_unavailable"
    ]

    private static let localRequestCodes: Set<String> = [
        "invalid_identity", "request_too_large", "invalid_release_filter"
    ]

    private static let invalidKeyCodes: Set<String> = [
        "license_not_found", "invalid_license", "license_invalid"
    ]

    private static let seatLimitCodes: Set<String> = [
        "seat_limit_exceeded", "device_limit_reached"
    ]

    private static func category(of error: APIError) -> Category {
        let code = error.code?.lowercased()
        if let code {
            if configurationCodes.contains(code) { return .configuration }
            if localRequestCodes.contains(code) { return .invalidRequest }
            if invalidKeyCodes.contains(code) { return .invalidLicenseKey }
            if seatLimitCodes.contains(code) { return .seatLimitReached }
        }
        if error.isLicenseTerminalError || error.status == 410 { return .licenseNotUsable }
        switch error.status {
        case 0:
            // Status 0 is either a local response/identity rejection (coded)
            // or a transport failure (uncoded).
            return code == nil ? .network : .invalidResponse
        case 408:
            return .network
        case 429:
            return .rateLimited
        case 401, 403:
            return .unauthorized
        case 400..<500:
            return .invalidRequest
        case 500..<600:
            return .server
        default:
            return .unknown
        }
    }

    private static func category(of error: LicenseSeatError) -> Category {
        switch error {
        case .noActiveLicense:
            return .notActivated
        case .apiKeyRequired, .productSlugRequired, .cryptoUnavailable:
            return .configuration
        case .invalidOfflineToken, .invalidKeyId, .invalidPublicKey:
            return .invalidResponse
        case .networkError:
            return .network
        case .deviceIdentifierError:
            return .deviceIdentity
        case .cacheError:
            return .storage
        case .validationFailed(let reason), .activationFailed(let reason):
            // Superseded operations are reported through validationFailed for
            // source compatibility; they are cancellations, not failures.
            return reason.contains("superseded") ? .cancelled : .invalidResponse
        }
    }
}

extension LicenseSeatFailure: LocalizedError {
    public var errorDescription: String? { userMessage }
}
