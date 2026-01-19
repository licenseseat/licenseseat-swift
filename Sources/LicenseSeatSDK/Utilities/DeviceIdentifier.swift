//
//  DeviceIdentifier.swift
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
#if canImport(IOKit)
import IOKit
#endif
#if os(watchOS)
import WatchKit
#endif

/// Device identifier generator
///
/// Generates a stable, unique identifier for the current device.
/// The identifier is cached after first generation to ensure stability.
enum DeviceIdentifier {

    /// Key used to persist the cached device identifier
    private static let cacheKey = "licenseseat_device_identifier"

    /// Generate a unique device identifier
    ///
    /// This method returns a stable identifier that persists across app launches.
    /// On first call, it generates an identifier and caches it. Subsequent calls
    /// return the cached value.
    static func generate() -> String {
        // Check for cached identifier first
        if let cached = getCachedIdentifier() {
            return cached
        }

        // Generate a new identifier
        let identifier = generateNewIdentifier()

        // Cache it for future calls
        cacheIdentifier(identifier)

        return identifier
    }

    /// Generate a fresh device identifier (internal, for testing)
    private static func generateNewIdentifier() -> String {
        #if os(macOS)
        // Try to get hardware UUID on macOS
        if let hardwareUUID = getMacHardwareUUID() {
            return "mac-\(hardwareUUID.lowercased())"
        }
        #endif

        // Fallback to composite identifier based on stable device characteristics
        let components = [
            getDeviceModel(),
            getSystemVersion(),
            getBundleIdentifier(),
            getPreferredLanguage(),
            String(getScreenResolutionHash())
        ]

        let composite = components.joined(separator: "|")
        let hash = composite.simpleHash()

        // Generate a stable random suffix once (not time-based)
        let randomSuffix = UUID().uuidString.prefix(8).lowercased()

        #if os(iOS) || os(tvOS)
        return "ios-\(hash)-\(randomSuffix)"
        #elseif os(watchOS)
        return "watch-\(hash)-\(randomSuffix)"
        #elseif os(macOS)
        return "mac-\(hash)-\(randomSuffix)"
        #else
        return "swift-\(hash)-\(randomSuffix)"
        #endif
    }

    /// Retrieve the cached device identifier from UserDefaults
    private static func getCachedIdentifier() -> String? {
        return UserDefaults.standard.string(forKey: cacheKey)
    }

    /// Cache the device identifier to UserDefaults
    private static func cacheIdentifier(_ identifier: String) {
        UserDefaults.standard.set(identifier, forKey: cacheKey)
    }

    /// Clear the cached device identifier (for testing purposes)
    static func clearCache() {
        UserDefaults.standard.removeObject(forKey: cacheKey)
    }
    
    #if os(macOS) && canImport(IOKit)
    /// Get hardware UUID on macOS
    private static func getMacHardwareUUID() -> String? {
        // IOKit approach for hardware UUID
        let platformExpert = IOServiceGetMatchingService(
            kIOMainPortDefault,
            IOServiceMatching("IOPlatformExpertDevice")
        )
        
        guard platformExpert != 0 else { return nil }
        defer { IOObjectRelease(platformExpert) }
        
        let key = "IOPlatformUUID" as CFString
        guard let uuidCF = IORegistryEntryCreateCFProperty(
            platformExpert,
            key,
            kCFAllocatorDefault,
            0
        ) else { return nil }
        
        guard let uuid = uuidCF.takeRetainedValue() as? String else { return nil }
        return uuid
    }
    #endif
    
    /// Get device model
    private static func getDeviceModel() -> String {
        #if os(iOS) || os(tvOS)
        return UIDevice.current.model
        #elseif os(watchOS)
        return "Apple Watch"
        #elseif os(macOS)
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var model = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.model", &model, &size, nil, 0)
        return String(cString: model)
        #else
        return "Unknown"
        #endif
    }
    
    /// Get system version
    private static func getSystemVersion() -> String {
        #if os(iOS) || os(tvOS)
        return UIDevice.current.systemVersion
        #elseif os(watchOS)
        return WKInterfaceDevice.current().systemVersion
        #elseif os(macOS)
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
        #else
        return "Unknown"
        #endif
    }
    
    /// Get bundle identifier
    private static func getBundleIdentifier() -> String {
        return Bundle.main.bundleIdentifier ?? "unknown"
    }
    
    /// Get preferred language
    private static func getPreferredLanguage() -> String {
        return Locale.preferredLanguages.first ?? "en"
    }
    
    /// Get screen resolution hash
    private static func getScreenResolutionHash() -> Int {
        #if os(iOS) || os(tvOS)
        let screen = UIScreen.main
        let scale = screen.scale
        let bounds = screen.bounds
        return "\(bounds.width)x\(bounds.height)@\(scale)".hashValue
        #elseif os(macOS)
        if let screen = NSScreen.main {
            let scale = screen.backingScaleFactor
            let frame = screen.frame
            return "\(frame.width)x\(frame.height)@\(scale)".hashValue
        }
        return 0
        #else
        return 0
        #endif
    }
}

// MARK: - Hash Utilities

private extension String {
    func simpleHash() -> String {
        var hasher = Hasher()
        hasher.combine(self)
        let hash = abs(hasher.finalize())
        return String(hash, radix: 36)
    }
} 