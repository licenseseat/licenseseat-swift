// LicenseSeat.swift
// Entry point for LicenseSeat Swift SDK

import Foundation

public final class LicenseSeat {
    public static let shared = LicenseSeat()

    private let config: LicenseSeatConfig
    private let cache: LicenseSeatCache
    private let api: LicenseSeatAPI
    private var validationTimer: Timer?

    private init(config: LicenseSeatConfig = .default) {
        self.config = config
        self.cache = LicenseSeatCache(prefix: config.storagePrefix)
        self.api = LicenseSeatAPI(config: config)
        // setup timers, listeners, etc here
    }

    public func activate(licenseKey: String) async throws -> License {
        let deviceId = config.deviceIdentifier ?? LicenseSeatUtils.generateDeviceId()
        let payload = ActivationPayload(licenseKey: licenseKey, deviceIdentifier: deviceId)
        
        let activation = try await api.activateLicense(payload: payload)

        let license = License(
            licenseKey: licenseKey,
            deviceIdentifier: deviceId,
            activation: activation,
            activatedAt: Date(),
            lastValidated: Date()
        )

        cache.setLicense(license)
        return license
    }

    public func validate(licenseKey: String) async throws -> LicenseValidationResult {
        let deviceId = cache.getLicense()?.deviceIdentifier ?? config.deviceIdentifier ?? ""
        let result = try await api.validateLicense(licenseKey: licenseKey, deviceId: deviceId)
        cache.updateValidation(result)
        return result
    }

    public func deactivate() async throws {
        guard let license = cache.getLicense() else { return }
        try await api.deactivateLicense(licenseKey: license.licenseKey, deviceId: license.deviceIdentifier)
        cache.clearLicense()
    }

    /// Returns the license currently stored on disk, if any.
    public func currentLicense() -> License? {
        cache.getLicense()
    }

    public func reset() {
        cache.clearAll()
    }
}

// LicenseSeatConfig.swift
public struct LicenseSeatConfig {
    public var apiBaseUrl: String
    public var apiKey: String?
    public var storagePrefix: String
    public var deviceIdentifier: String?

    public static var `default`: LicenseSeatConfig {
        return LicenseSeatConfig(
            apiBaseUrl: "https://api.licenseseat.com",
            apiKey: nil,
            storagePrefix: "licenseseat_",
            deviceIdentifier: nil
        )
    }
}

// LicenseSeatCache.swift
import Foundation

final class LicenseSeatCache {
    private let prefix: String

    init(prefix: String) {
        self.prefix = prefix
    }

    func setLicense(_ license: License) {
        if let data = try? JSONEncoder().encode(license) {
            UserDefaults.standard.set(data, forKey: prefix + "license")
        }
    }

    func getLicense() -> License? {
        guard let data = UserDefaults.standard.data(forKey: prefix + "license") else { return nil }
        return try? JSONDecoder().decode(License.self, from: data)
    }

    func updateValidation(_ validation: LicenseValidationResult) {
        guard var license = getLicense() else { return }
        license.validation = validation
        setLicense(license)
    }

    func clearLicense() {
        UserDefaults.standard.removeObject(forKey: prefix + "license")
    }

    func clearAll() {
        clearLicense()
    }
}

// License.swift
import Foundation

public struct License: Codable {
    let licenseKey: String
    let deviceIdentifier: String
    let activation: ActivationResult
    let activatedAt: Date
    var lastValidated: Date
    var validation: LicenseValidationResult?
}

public struct LicenseValidationResult: Codable {
    let valid: Bool
    let reason: String?
    let offline: Bool
}

struct ActivationResult: Codable {
    let id: String
    let activatedAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case activatedAt = "activated_at"
    }
}

// LicenseSeatAPI.swift
import Foundation

final class LicenseSeatAPI {
    private let config: LicenseSeatConfig

    init(config: LicenseSeatConfig) {
        self.config = config
    }

    func activateLicense(payload: ActivationPayload) async throws -> ActivationResult {
        try await post(path: "/activations/activate", body: payload)
    }

    func validateLicense(licenseKey: String, deviceId: String) async throws -> LicenseValidationResult {
        let body = [
            "license_key": licenseKey,
            "device_identifier": deviceId
        ]
        return try await post(path: "/licenses/validate", body: body)
    }

    func deactivateLicense(licenseKey: String, deviceId: String) async throws {
        let body = [
            "license_key": licenseKey,
            "device_identifier": deviceId
        ]

        struct Empty: Decodable {}
        let _: Empty = try await post(path: "/activations/deactivate", body: body)
    }

    private func post<T: Codable, R: Decodable>(path: String, body: T) async throws -> R {
        guard let url = URL(string: config.apiBaseUrl + path) else {
            throw URLError(.badURL)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)

        if let apiKey = config.apiKey {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }

        return try JSONDecoder().decode(R.self, from: data)
    }
}

// ActivationPayload.swift
struct ActivationPayload: Codable {
    let licenseKey: String
    let deviceIdentifier: String

    enum CodingKeys: String, CodingKey {
        case licenseKey = "license_key"
        case deviceIdentifier = "device_identifier"
    }
}

// LicenseSeatUtils.swift
import Foundation

enum LicenseSeatUtils {
    static func generateDeviceId() -> String {
        return UUID().uuidString
    }
}
