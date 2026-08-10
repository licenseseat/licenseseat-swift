# Privacy

Understand what the SDK sends, what can be disabled, and what an integrating application must disclose.

## Required Licensing Data

LicenseSeat sends the customer license key and an app-scoped installation identifier to activate, validate, heartbeat, deactivate, and issue offline grants. The installation identifier uses the canonical HTTP field `fingerprint`; by default it is a random value and is not derived from hardware characteristics, IDFA, or IDFV.

The LicenseSeat service also observes the request's source IP address, retains it with licensing activity, and can derive coarse country/city information for product analytics. The SDK does not separately inspect the network interface or insert an IP address into its JSON payload.

Licensing requests and heartbeat timing are retained to provide activation state and service activity. These identifiers and interactions remain necessary when optional telemetry is disabled.

## Optional Telemetry

``LicenseSeatConfig/telemetryEnabled`` defaults to `true`. When enabled, the SDK includes:

- SDK, OS, platform, device model/type, and architecture;
- processor count and rounded physical memory;
- locale, language, and timezone;
- host-app version and build number;
- screen resolution and display scale.

Set `telemetryEnabled` to `false` to omit this telemetry object. Activation, validation, heartbeat, deactivation, and offline grants continue to send the required licensing data described above.

Developer-supplied `ActivationOptions.metadata` is sent exactly as provided. Do not include personal data or secrets unless the host application intentionally collects, protects, retains, and discloses it.

## Apple Privacy Manifest

The Swift package bundles `PrivacyInfo.xcprivacy` as a target resource. It declares these potentially collected categories:

- User ID for the customer license key;
- Device ID for the app-scoped installation identifier;
- Coarse Location derived from the retained source IP;
- Product Interaction for licensing requests and heartbeat activity;
- Other Diagnostic Data for optional device/application telemetry.

The manifest marks the categories as linked, not used for tracking, and used for app functionality and/or analytics. It also declares `NSPrivacyAccessedAPICategoryUserDefaults` with reason `CA92.1` because UserDefaults is used for app-local compatibility storage and migration.

The package manifest contributes only the SDK's practices. The integrating application remains responsible for its complete App Store Connect privacy answers, privacy policy, consent, retention/deletion behavior, developer-supplied metadata, and any other SDKs. Disabling optional telemetry alone does not establish compliance with GDPR or another legal regime.

For current platform requirements, consult Apple's [privacy manifest documentation](https://developer.apple.com/documentation/bundleresources/privacy-manifest-files) and [App privacy details](https://developer.apple.com/app-store/app-privacy-details/).
