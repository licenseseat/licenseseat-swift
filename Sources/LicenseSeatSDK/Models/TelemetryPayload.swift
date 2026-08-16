//
//  TelemetryPayload.swift
//  LicenseSeatSDK
//
//  Created by LicenseSeat on 2025.
//  Copyright © 2025 LicenseSeat. All rights reserved.
//

import Foundation
#if canImport(Darwin)
import Darwin
#endif
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

struct TelemetryPayload: Encodable, Sendable {
    let sdkName: String
    let sdkVersion: String
    let osName: String
    let osVersion: String
    let platform: String
    let deviceModel: String
    let locale: String
    let timezone: String
    let appVersion: String?
    let appBuild: String?
    let deviceType: String?
    let architecture: String?
    let cpuCores: Int?
    let memoryGb: Int?
    let language: String?
    let screenResolution: String?
    let displayScale: Double?

    enum CodingKeys: String, CodingKey {
        case sdkName = "sdk_name"
        case sdkVersion = "sdk_version"
        case osName = "os_name"
        case osVersion = "os_version"
        case platform
        case deviceModel = "device_model"
        case locale
        case timezone
        case appVersion = "app_version"
        case appBuild = "app_build"
        case deviceType = "device_type"
        case architecture
        case cpuCores = "cpu_cores"
        case memoryGb = "memory_gb"
        case language
        case screenResolution = "screen_resolution"
        case displayScale = "display_scale"
    }

    /// Collect the current device attributes.
    /// - Parameters:
    ///   - appVersion: Host-supplied application version. `nil` falls back to
    ///     the main bundle's `CFBundleShortVersionString`.
    ///   - appBuild: Host-supplied application build. `nil` falls back to the
    ///     main bundle's `CFBundleVersion`.
    ///
    /// Both overrides and bundle values pass the same bounds check, so an
    /// oversized or control-character value is omitted instead of shipped.
    static func collect(
        appVersion: String? = nil,
        appBuild: String? = nil
    ) -> TelemetryPayload {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        let bundleInfo = Bundle.main.infoDictionary
        return TelemetryPayload(
            sdkName: "swift",
            sdkVersion: LicenseSeatConfig.sdkVersion,
            osName: currentOSName(),
            osVersion: "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)",
            platform: currentPlatform(),
            deviceModel: currentDeviceModel(),
            locale: Locale.current.identifier,
            timezone: TimeZone.current.identifier,
            appVersion: resolvedAppText(
                override: appVersion,
                bundleValue: bundleInfo?["CFBundleShortVersionString"] as? String
            ),
            appBuild: resolvedAppText(
                override: appBuild,
                bundleValue: bundleInfo?["CFBundleVersion"] as? String
            ),
            deviceType: currentDeviceType(),
            architecture: currentArchitecture(),
            cpuCores: currentCPUCores(),
            memoryGb: currentMemoryGb(),
            language: currentLanguage(),
            screenResolution: currentScreenResolution(),
            displayScale: currentDisplayScale()
        )
    }

    func toDictionary() -> [String: Any] {
        var dict: [String: Any] = [
            "sdk_name": sdkName,
            "sdk_version": sdkVersion,
            "os_name": osName,
            "os_version": osVersion,
            "platform": platform,
            "device_model": deviceModel,
            "locale": locale,
            "timezone": timezone
        ]
        if let appVersion { dict["app_version"] = appVersion }
        if let appBuild { dict["app_build"] = appBuild }
        if let deviceType { dict["device_type"] = deviceType }
        if let architecture { dict["architecture"] = architecture }
        if let cpuCores { dict["cpu_cores"] = cpuCores }
        if let memoryGb { dict["memory_gb"] = memoryGb }
        if let language { dict["language"] = language }
        if let screenResolution { dict["screen_resolution"] = screenResolution }
        if let displayScale { dict["display_scale"] = displayScale }
        return dict
    }

    // MARK: - Existing helpers

    /// Resolve one application attribute. An explicit host value wins outright,
    /// so a malformed override is dropped rather than silently replaced by an
    /// unrelated bundle string.
    private static func resolvedAppText(
        override: String?,
        bundleValue: String?
    ) -> String? {
        guard override == nil else { return safeAppText(override) }
        return safeAppText(bundleValue)
    }

    /// Bound an application-supplied telemetry string the same way the Rust SDK
    /// bounds its configuration text, so a malformed value is dropped rather
    /// than embedded in an outbound request body.
    private static func safeAppText(_ value: String?) -> String? {
        guard let value,
              !value.isEmpty,
              value.utf8.count <= 255,
              value.unicodeScalars.allSatisfy({ $0.value > 31 && $0.value != 127 }) else {
            return nil
        }
        return value
    }

    private static func currentOSName() -> String {
        #if os(macOS)
        return "macOS"
        #elseif os(iOS)
        return "iOS"
        #elseif os(tvOS)
        return "tvOS"
        #elseif os(watchOS)
        return "watchOS"
        #elseif os(visionOS)
        return "visionOS"
        #elseif os(Linux)
        return "Linux"
        #else
        return "Unknown"
        #endif
    }

    private static func currentPlatform() -> String {
        return "native"
    }

    private static func currentDeviceModel() -> String {
        #if canImport(Darwin)
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        guard size > 0 else { return "Unknown" }
        var model = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.model", &model, &size, nil, 0)
        return String(cString: model)
        #elseif os(Linux)
        let modelPaths = [
            "/sys/devices/virtual/dmi/id/product_name",
            "/sys/firmware/devicetree/base/model"
        ]
        for path in modelPaths {
            if let value = try? String(contentsOfFile: path, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines),
               !value.isEmpty {
                return value
            }
        }
        return "Linux"
        #else
        return "Unknown"
        #endif
    }

    // MARK: - New telemetry helpers

    private static func currentDeviceType() -> String? {
        #if os(macOS)
        return "desktop"
        #elseif os(watchOS)
        return "watch"
        #elseif os(tvOS)
        return "tv"
        #elseif os(visionOS)
        return "headset"
        #elseif os(Linux)
        return "unknown"
        #elseif canImport(UIKit)
        switch UIDevice.current.userInterfaceIdiom {
        case .phone:
            return "phone"
        case .pad:
            return "tablet"
        case .tv:
            return "tv"
        case .mac:
            return "desktop"
        default:
            return "unknown"
        }
        #else
        return nil
        #endif
    }

    /// Report the architecture using the vocabulary of Rust's
    /// `std::env::consts::ARCH`, which the other LicenseSeat SDKs already send.
    /// Matching values keep dashboard buckets from splitting per SDK.
    private static func currentArchitecture() -> String? {
        #if arch(arm64)
        return "aarch64"
        #elseif arch(x86_64)
        return "x86_64"
        #else
        return nil
        #endif
    }

    private static func currentCPUCores() -> Int? {
        return ProcessInfo.processInfo.processorCount
    }

    private static func currentMemoryGb() -> Int? {
        let bytes = ProcessInfo.processInfo.physicalMemory
        let gb = Double(bytes) / (1024.0 * 1024.0 * 1024.0)
        return Int(gb.rounded())
    }

    private static func currentLanguage() -> String? {
        if #available(macOS 13, iOS 16, tvOS 16, watchOS 9, *) {
            return Locale.current.language.languageCode?.identifier
        } else {
            let id = Locale.current.identifier
            return id.components(separatedBy: CharacterSet(charactersIn: "_-")).first
        }
    }

    private static func currentScreenResolution() -> String? {
        #if os(macOS) && canImport(AppKit)
        guard let screen = NSScreen.main else { return nil }
        let size = screen.frame.size
        let scale = screen.backingScaleFactor
        let w = Int(size.width * scale)
        let h = Int(size.height * scale)
        return "\(w)x\(h)"
        #elseif canImport(UIKit) && !os(watchOS)
        let bounds = UIScreen.main.nativeBounds.size
        return "\(Int(bounds.width))x\(Int(bounds.height))"
        #else
        return nil
        #endif
    }

    private static func currentDisplayScale() -> Double? {
        #if os(macOS) && canImport(AppKit)
        guard let screen = NSScreen.main else { return nil }
        return Double(screen.backingScaleFactor)
        #elseif canImport(UIKit) && !os(watchOS)
        return Double(UIScreen.main.scale)
        #else
        return nil
        #endif
    }
}
