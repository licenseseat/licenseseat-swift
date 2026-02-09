//
//  TelemetryPayload.swift
//  LicenseSeatSDK
//
//  Created by LicenseSeat on 2025.
//  Copyright © 2025 LicenseSeat. All rights reserved.
//

import Foundation
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

struct TelemetryPayload: Encodable, Sendable {
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

    static func collect() -> TelemetryPayload {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return TelemetryPayload(
            sdkVersion: LicenseSeatConfig.sdkVersion,
            osName: currentOSName(),
            osVersion: "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)",
            platform: currentPlatform(),
            deviceModel: currentDeviceModel(),
            locale: Locale.current.identifier,
            timezone: TimeZone.current.identifier,
            appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
            appBuild: Bundle.main.infoDictionary?["CFBundleVersion"] as? String,
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
        #else
        return "Unknown"
        #endif
    }

    private static func currentPlatform() -> String {
        return "native"
    }

    private static func currentDeviceModel() -> String {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        guard size > 0 else { return "Unknown" }
        var model = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.model", &model, &size, nil, 0)
        return String(cString: model)
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

    private static func currentArchitecture() -> String? {
        #if arch(arm64)
        return "arm64"
        #elseif arch(x86_64)
        return "x64"
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
