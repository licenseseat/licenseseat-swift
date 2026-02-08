//
//  TelemetryPayload.swift
//  LicenseSeatSDK
//
//  Created by LicenseSeat on 2025.
//  Copyright © 2025 LicenseSeat. All rights reserved.
//

import Foundation

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

    static func collect() -> TelemetryPayload {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return TelemetryPayload(
            sdkVersion: LicenseSeatConfig.sdkVersion,
            osName: currentOSName(),
            osVersion: "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)",
            platform: currentOSName(),
            deviceModel: currentDeviceModel(),
            locale: Locale.current.identifier,
            timezone: TimeZone.current.identifier,
            appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
            appBuild: Bundle.main.infoDictionary?["CFBundleVersion"] as? String
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
        return dict
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
        #else
        return "Unknown"
        #endif
    }

    private static func currentDeviceModel() -> String {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        guard size > 0 else { return "Unknown" }
        var model = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.model", &model, &size, nil, 0)
        return String(cString: model)
    }
}
