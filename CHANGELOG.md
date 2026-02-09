# Changelog

All notable changes to LicenseSeat will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.4.1] - 2026-02-09

### Fixed
- Offline token URL path (`/offline-token` → `/offline_token`) to match Rails API routes
- Signing key URL path (`/signing-keys/` → `/signing_keys/`) to match Rails API routes

### Changed
- `syncOfflineAssets()` and `verifyCachedOffline()` are now public APIs
- Added offline token download & verification to stress test suite

## [0.4.0] - 2026-02-09

### Added
- Auto-collected device telemetry sent with every API request (17 fields: sdk_name, sdk_version, os_name, os_version, platform, device_model, device_type, architecture, cpu_cores, memory_gb, locale, language, timezone, app_version, app_build, screen_resolution, display_scale)
- Heartbeat endpoint (`heartbeat()`) for periodic health-check pings
- Auto-heartbeat timer that runs alongside auto-validation (default: every 5 minutes)
- `heartbeatInterval` configuration option (default 300 seconds, set to 0 to disable)
- `telemetryEnabled` configuration option to opt out of telemetry (default `true`)
- `heartbeat:success` event emitted on successful heartbeat pings

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

[0.4.0]: https://github.com/licenseseat/licenseseat-swift/releases/tag/v0.4.0
[1.0.0]: https://github.com/licenseseat/licenseseat-swift/releases/tag/v1.0.0