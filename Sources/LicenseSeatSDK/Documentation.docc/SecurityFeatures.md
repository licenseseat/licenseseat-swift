# Security Features

In-depth guide to LicenseSeat's security mechanisms and best practices.

## Overview

LicenseSeat implements multiple layers of security to protect your software licenses from tampering, piracy, and unauthorized use. This guide covers the security features and how to maximize protection.

## Cryptographic Verification

### Ed25519 Signatures

All offline licenses are cryptographically signed using Ed25519:

```swift
// Automatic signature verification
let result = try await licenseSeat.validate(licenseKey: "KEY")
// SDK verifies Ed25519 signature if offline
```

**Security Properties:**
- 128-bit security level
- Resistant to timing attacks
- Fast verification (< 1ms)
- Small signature size (64 bytes)

### Platform Implementation

- **Apple Platforms**: Native CryptoKit (hardware-accelerated when available)
- **Linux**: SwiftCrypto (constant-time implementation)

## Clock Tamper Detection

The SDK detects system clock manipulation attempts:

```swift
let config = LicenseSeatConfig(
    maxClockSkewMs: 300000  // 5 minutes tolerance
)
```

**How it works:**
1. Records timestamp after each successful online validation
2. Compares current time against last known good time
3. Rejects validation if clock moved backwards beyond tolerance

**Protection against:**
- Setting clock back to extend trial periods
- Bypassing time-based license expiration
- Replay attacks with old offline licenses

## Device Binding

### Secure Device Identification

```swift
// Automatic device ID generation
let deviceId = DeviceIdentifier.generate()
// Output: "mac-9559bc39-868b-53ed-b6e1-7d20436b5dc3"
```

**Platform-specific methods:**
- **macOS**: Hardware UUID from IOKit (tamper-resistant)
- **iOS**: Composite of device characteristics
- **Linux**: Machine ID + hardware info

### License-Device Binding

Licenses are bound to specific devices:

```swift
// Activation binds to device
let license = try await licenseSeat.activate(
    licenseKey: "KEY",
    options: ActivationOptions(
        deviceIdentifier: customId  // Optional custom ID
    )
)
```

## Secure Storage

### Cache Security

```swift
// Current implementation
let cache = LicenseCache(prefix: "myapp_")
// Stores in UserDefaults + Documents
```

### Keychain Integration (Recommended)

```swift
// Example Keychain wrapper
class SecureLicenseCache {
    private let keychain = Keychain(service: "com.myapp.licenses")
    
    func setLicense(_ license: License) throws {
        let data = try JSONEncoder().encode(license)
        try keychain
            .accessibility(.whenUnlockedThisDeviceOnly)
            .set(data, key: "license")
    }
    
    func getLicense() -> License? {
        guard let data = try? keychain.getData("license") else { return nil }
        return try? JSONDecoder().decode(License.self, from: data)
    }
}
```

## Network Security

### TLS/HTTPS Only

All API communication uses HTTPS:

```swift
// Enforced HTTPS
let config = LicenseSeatConfig(
    apiBaseUrl: "https://api.licenseseat.com"  // https:// required
)
```

### API Key Protection

```swift
// Never hardcode API keys
let apiKey = ProcessInfo.processInfo.environment["LICENSESEAT_API_KEY"]
let config = LicenseSeatConfig(apiKey: apiKey)
```

### Certificate Pinning (Optional)

```swift
// Implement URLSessionDelegate for cert pinning
class PinnedSessionDelegate: NSObject, URLSessionDelegate {
    func urlSession(_ session: URLSession, 
                    didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        // Verify server certificate
        guard let serverTrust = challenge.protectionSpace.serverTrust,
              let certificate = SecTrustGetCertificateAtIndex(serverTrust, 0) else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        
        // Compare with pinned certificate
        let pinnedCertData = // your pinned cert data
        let serverCertData = SecCertificateCopyData(certificate) as Data
        
        if pinnedCertData == serverCertData {
            completionHandler(.useCredential, URLCredential(trust: serverTrust))
        } else {
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }
}
```

## Anti-Tampering Measures

### Constant-Time Comparisons

The SDK uses constant-time string comparison for license keys:

```swift
// Internal implementation
func constantTimeEqual(_ a: String, _ b: String) -> Bool {
    guard a.count == b.count else { return false }
    var result = 0
    for (charA, charB) in zip(a, b) {
        result |= Int(charA.asciiValue ?? 0) ^ Int(charB.asciiValue ?? 0)
    }
    return result == 0
}
```

### Canonical JSON

Ensures consistent serialization for signature verification:

```swift
// Deterministic JSON with sorted keys
let canonical = try CanonicalJSON.stringify(payload)
// Same output regardless of input order
```

## Best Practices

### 1. Secure API Key Storage

**❌ Don't:**
```swift
let config = LicenseSeatConfig(apiKey: "sk_live_abcd1234")
```

**✅ Do:**
```swift
// Use environment variables
let apiKey = ProcessInfo.processInfo.environment["LICENSESEAT_API_KEY"]

// Or secure configuration service
let apiKey = try ConfigService.shared.getSecureValue("api_key")
```

### 2. Validate Critical Operations

```swift
// Always validate before enabling features
func enablePremiumFeatures() async throws {
    let result = try await licenseSeat.validate(licenseKey: currentKey)
    guard result.valid else {
        throw FeatureError.licenseRequired
    }
    // Enable features
}
```

### 3. Implement App Attestation

```swift
#if os(iOS)
import DeviceCheck

func attestDevice() async throws {
    let service = DCAppAttestService.shared
    guard service.isSupported else { return }
    
    let keyId = try await service.generateKey()
    let clientData = Data(UUID().uuidString.utf8)
    let attestation = try await service.attestKey(keyId, clientDataHash: clientData.sha256())
    
    // Send attestation to your server
}
#endif
```

### 4. Obfuscate Sensitive Logic

```swift
// Use symbols instead of strings for critical checks
private enum SecurityFlags {
    static let δ = 0x1  // Valid
    static let λ = 0x2  // Active
    static let ω = 0x4  // Premium
}

func checkAccess() -> Bool {
    let flags = getLicenseFlags()
    return (flags & SecurityFlags.δ) != 0 &&
           (flags & SecurityFlags.λ) != 0
}
```

### 5. Runtime Integrity Checks

```swift
// Detect debugger attachment
func isDebuggerAttached() -> Bool {
    var info = kinfo_proc()
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
    var size = MemoryLayout<kinfo_proc>.stride
    
    let result = sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0)
    return result == 0 && (info.kp_proc.p_flag & P_TRACED) != 0
}

// Check code signature
func verifyCodeSignature() -> Bool {
    guard let url = Bundle.main.executableURL else { return false }
    var staticCode: SecStaticCode?
    
    let result = SecStaticCodeCreateWithPath(url as CFURL, [], &staticCode)
    guard result == errSecSuccess, let code = staticCode else { return false }
    
    let status = SecStaticCodeCheckValidity(code, [.checkAllArchitectures], nil)
    return status == errSecSuccess
}
```

## Security Checklist

- [ ] API key stored securely (environment/keychain)
- [ ] HTTPS enforced for all API calls
- [ ] Offline validation enabled
- [ ] Clock tamper detection configured
- [ ] Device binding implemented
- [ ] Critical operations re-validate license
- [ ] Sensitive data in Keychain (not UserDefaults)
- [ ] Code signature verification (production)
- [ ] Debugger detection (optional)
- [ ] Certificate pinning (high-security apps)

## Reporting Security Issues

Found a security vulnerability? Please report it to security@licenseseat.com with:

1. Description of the vulnerability
2. Steps to reproduce
3. Potential impact
4. Suggested fix (if any)

We'll respond within 48 hours and work on a fix immediately. 