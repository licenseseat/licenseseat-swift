import XCTest
#if canImport(CryptoKit)
import CryptoKit
#elseif canImport(Crypto)
import Crypto
#endif
import Combine
@testable import LicenseSeatSDK

@MainActor
final class LicenseSeatSDKTests: XCTestCase {
    private var sdk: LicenseSeat!
    private var cancellables: Set<AnyCancellable> = []
    
    override func setUp() {
        super.setUp()
        URLProtocol.registerClass(MockURLProtocol.self)
        MockURLProtocol.reset()
        
        let cfg = LicenseSeatConfig(
            apiBaseUrl: "https://api.test.com",
            apiKey: "unit-test",
            storagePrefix: "test_",
            autoValidateInterval: 3600, // won't trigger in unit time
            offlineFallbackEnabled: false // disable background offline asset sync for predictable request order
        )
        let urlConf = URLSessionConfiguration.ephemeral
        urlConf.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: urlConf)
        sdk = LicenseSeat(config: cfg, urlSession: session)
        sdk.cache.clear() // clean slate
    }
    
    override func tearDown() {
        sdk.cache.clear()
        URLProtocol.unregisterClass(MockURLProtocol.self)
        cancellables.removeAll()
        super.tearDown()
    }
    
    func testActivationValidationDeactivationFlow() async throws {
        // Prepare stubbed responses
        let activationJSON: [String: Any] = [
            "id": "act-123",
            "activated_at": ISO8601DateFormatter().string(from: Date())
        ]
        let validationJSON: [String: Any] = [
            "valid": true,
            "offline": false,
            "reason": NSNull(),
            "reason_code": NSNull(),
            "active_entitlements": []
        ]
        var requestSequence: [String] = []
        
        MockURLProtocol.requestHandler = { request in
            requestSequence.append(request.url!.path)
            switch request.url!.path {
            case "/activations/activate":
                let data = try JSONSerialization.data(withJSONObject: activationJSON)
                let resp = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type":"application/json"])!;
                return (resp, data)
            case "/licenses/validate":
                let data = try JSONSerialization.data(withJSONObject: validationJSON)
                let resp = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type":"application/json"])!;
                return (resp, data)
            case "/activations/deactivate":
                let resp = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type":"application/json"])!;
                return (resp, Data("{}".utf8))
            default:
                let resp = HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!;
                return (resp, Data())
            }
        }
        
        // Expectation for event emissions
        let activationExp = expectation(description: "activation")
        let validationExp = expectation(description: "validation")
        let deactivationExp = expectation(description: "deactivation")
        
        sdk.on("activation:success") { _ in activationExp.fulfill() }.store(in: &cancellables)
        sdk.on("validation:success") { _ in validationExp.fulfill() }.store(in: &cancellables)
        sdk.on("deactivation:success") { _ in deactivationExp.fulfill() }.store(in: &cancellables)
        
        // 1. Activate
        let license = try await sdk.activate(licenseKey: "TEST-KEY")
        XCTAssertEqual(license.licenseKey, "TEST-KEY")
        XCTAssertNotNil(sdk.currentLicense())
        
        // 2. Validate
        let validation = try await sdk.validate(licenseKey: "TEST-KEY")
        XCTAssertTrue(validation.valid)
        
        // 3. Deactivate
        try await sdk.deactivate()
        XCTAssertNil(sdk.currentLicense())
        
        // Wait for events
        await fulfillment(of: [activationExp, validationExp, deactivationExp], timeout: 5)
        
        // Ensure correct endpoints called in order (ignore any extra calls)
        XCTAssertGreaterThanOrEqual(requestSequence.count, 3)
        XCTAssertEqual(requestSequence[0], "/activations/activate")
        XCTAssertEqual(requestSequence[1], "/licenses/validate")
        XCTAssertEqual(requestSequence.last, "/activations/deactivate")
    }
}
