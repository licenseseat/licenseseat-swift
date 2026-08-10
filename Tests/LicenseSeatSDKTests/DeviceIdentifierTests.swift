import XCTest
@testable import LicenseSeat

final class DeviceIdentifierTests: LicenseSeatTestCase {
    private var defaults: UserDefaults!
    private var keychainServiceSuffix: String!

    override func setUp() {
        super.setUp()
        let namespace = UUID().uuidString
        defaults = UserDefaults(suiteName: "DeviceIdentifierTests.\(namespace)")!
        keychainServiceSuffix = ".tests.\(namespace)"
        clearIdentifier()
    }

    override func tearDown() {
        clearIdentifier()
        defaults = nil
        keychainServiceSuffix = nil
        super.tearDown()
    }

    private func generateIdentifier() throws -> String {
        try DeviceIdentifier.generate(
            userDefaults: defaults,
            keychainServiceSuffix: keychainServiceSuffix
        )
    }

    private func clearIdentifier() {
        DeviceIdentifier.clearCache(
            userDefaults: defaults,
            keychainServiceSuffix: keychainServiceSuffix
        )
    }

    func testGenerateProducesNonEmptyString() throws {
        let id = try generateIdentifier()
        XCTAssertFalse(id.isEmpty)
    }

    func testGenerateProducesStableValues() throws {
        // The device identifier should be stable across multiple calls
        let first = try generateIdentifier()
        let second = try generateIdentifier()
        XCTAssertEqual(first, second, "Device identifier should be cached and return the same value")
    }

    func testClearCacheAllowsNewGeneration() throws {
        let first = try generateIdentifier()
        clearIdentifier()
        let second = try generateIdentifier()

        XCTAssertNotEqual(first, second)
    }

    func testMigratesLegacyIdentifierWithoutChangingSeatIdentity() throws {
        let legacyIdentifier = "mac-legacy-installation"
        defaults.set(
            legacyIdentifier,
            forKey: "licenseseat_device_identifier"
        )

        XCTAssertEqual(try generateIdentifier(), legacyIdentifier)
        XCTAssertEqual(try generateIdentifier(), legacyIdentifier)

        #if canImport(Security)
        XCTAssertNil(
            defaults.string(forKey: "licenseseat_device_identifier"),
            "Plaintext should be removed only after Keychain migration succeeds"
        )
        #endif
    }

    func testEmptyLegacyIdentifierIsReplacedWithUsableIdentity() throws {
        defaults.set("", forKey: "licenseseat_device_identifier")

        let identifier = try generateIdentifier()

        XCTAssertFalse(identifier.isEmpty)
        XCTAssertNotEqual(identifier, "")
        XCTAssertEqual(try generateIdentifier(), identifier)
    }

    func testLicenseResetDoesNotRotateInstallationIdentityOrConsumeASeat() throws {
        let first = try generateIdentifier()
        let licenseCache = LicenseCache(prefix: "licenseseat_", userDefaults: defaults)

        licenseCache.clear()

        XCTAssertEqual(try generateIdentifier(), first)
    }

    #if canImport(Security)
    func testLockedKeychainFailsIdentityAcquisitionInsteadOfRotatingSeat() {
        // A locked keychain answers reads with errSecInteractionNotAllowed.
        // Treating that as "no identity" would mint a fresh UUID, activate
        // under a rotated fingerprint, and burn a seat. It must fail with a
        // typed, recoverable error instead.
        DeviceIdentifier.keychainReadStatusOverrideForTesting = errSecInteractionNotAllowed
        defer { DeviceIdentifier.keychainReadStatusOverrideForTesting = nil }

        XCTAssertThrowsError(try generateIdentifier()) { error in
            XCTAssertEqual(error as? LicenseSeatError, .deviceIdentifierError)
        }
        XCTAssertNil(
            defaults.string(forKey: "licenseseat_device_identifier"),
            "A transient Keychain denial must not mint a fallback identity"
        )
    }

    func testKeychainAuthFailureFailsIdentityAcquisitionInsteadOfRotatingSeat() {
        DeviceIdentifier.keychainReadStatusOverrideForTesting = errSecAuthFailed
        defer { DeviceIdentifier.keychainReadStatusOverrideForTesting = nil }

        XCTAssertThrowsError(try generateIdentifier()) { error in
            XCTAssertEqual(error as? LicenseSeatError, .deviceIdentifierError)
        }
    }

    func testIdentityIsPreservedAcrossTransientKeychainDenial() throws {
        let original = try generateIdentifier()

        DeviceIdentifier.keychainReadStatusOverrideForTesting = errSecInteractionNotAllowed
        XCTAssertThrowsError(try generateIdentifier())
        DeviceIdentifier.keychainReadStatusOverrideForTesting = nil

        // Once the keychain answers again, the original identity is intact.
        XCTAssertEqual(try generateIdentifier(), original)
    }
    #endif

    func testCachedActivationIdentifierCanSeedProtectedInstallationIdentity() throws {
        let cachedActivationIdentifier = "mac-existing-activation"

        DeviceIdentifier.adoptCachedLicenseIdentifier(
            cachedActivationIdentifier,
            userDefaults: defaults,
            keychainServiceSuffix: keychainServiceSuffix
        )

        XCTAssertEqual(try generateIdentifier(), cachedActivationIdentifier)
    }

    func testCachedActivationRemainsAuthoritativeOverConflictingGeneratedIdentity() throws {
        let generatedIdentifier = try generateIdentifier()
        let cachedActivationIdentifier = "mac-existing-activation"

        DeviceIdentifier.adoptCachedLicenseIdentifier(
            cachedActivationIdentifier,
            userDefaults: defaults,
            keychainServiceSuffix: keychainServiceSuffix
        )

        XCTAssertNotEqual(generatedIdentifier, cachedActivationIdentifier)
        XCTAssertEqual(try generateIdentifier(), cachedActivationIdentifier)
    }

    func testGenerateProducesPlatformPrefixedString() throws {
        let id = try generateIdentifier()

        #if os(iOS) || os(tvOS)
        XCTAssertTrue(id.hasPrefix("ios-"), "iOS device identifier should have 'ios-' prefix")
        #elseif os(watchOS)
        XCTAssertTrue(id.hasPrefix("watch-"), "watchOS device identifier should have 'watch-' prefix")
        #elseif os(macOS)
        XCTAssertTrue(id.hasPrefix("mac-"), "macOS device identifier should have 'mac-' prefix")
        #else
        XCTAssertTrue(id.hasPrefix("swift-"), "Unknown platform device identifier should have 'swift-' prefix")
        #endif
    }
}
