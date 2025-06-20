# Changelog

All notable changes to LicenseSeatSDK will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.0.0] - 2025-06-20

### Added
- Complete Swift SDK with 100% feature parity with JavaScript SDK
- License activation, validation, and deactivation
- Online and offline validation with Ed25519 cryptographic signatures
- Automatic re-validation with configurable intervals
- Entitlement management with expiration support
- Network resilience with exponential backoff retry logic
- Event-driven architecture with traditional callbacks and Combine publishers
- Device fingerprinting with hardware UUID support on macOS
- Clock tamper detection and grace period enforcement
- Secure caching with UserDefaults and file backup
- Comprehensive test suite covering all major features
- Full DocC documentation with getting started guide
- Example command-line application
- GitHub Actions CI/CD pipeline
- SwiftLint integration for code quality

### Platform Support
- macOS 11+
- iOS 14+
- tvOS 14+
- watchOS 7+ (limited features)
- Linux (core features only)

### Security
- Ed25519 signature verification for offline licenses
- Constant-time string comparison to prevent timing attacks
- Clock skew detection (±5 minutes default)
- Secure storage with platform-appropriate mechanisms

[1.0.0]: https://github.com/licenseseat/licenseseat-swift/releases/tag/v1.0.0 