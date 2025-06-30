import XCTest
import Combine
@testable import LicenseSeat

// swiftlint:disable implicitly_unwrapped_optional
final class AutoValidationTests: XCTestCase {
    private var sdk: LicenseSeat!
    private var cancellables: Set<AnyCancellable> = []
    
    override func tearDown() {
        super.tearDown()
        // Ensure any background tasks are cancelled before resetting the protocol.
        if let instance = sdk {
            Task { @MainActor in
                instance.reset()
            }
        }
        sdk = nil
        MockURLProtocol.reset()
        cancellables.removeAll()
    }
    
    @MainActor
    func testAutoValidationCycleFires() async throws {
        // Stub network responses
        MockURLProtocol.requestHandler = { request in
            guard let url = request.url else {
                throw URLError(.badURL)
            }
            let path = url.path
            var json: [String: Any] = [:]
            switch path {
            case "/activations/activate":
                json = [
                    "id": "act_test",
                    "activated_at": "2025-01-01T00:00:00Z"
                ]
            case "/licenses/validate":
                json = [
                    "valid": true,
                    "offline": false
                ]
            default:
                // Return an empty JSON object for any other endpoint (e.g. offline license)
                json = [:]
            }
            let data = try JSONSerialization.data(withJSONObject: json)
            let response = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, data)
        }
        
        // URLSession configured with MockURLProtocol
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        
        // Configure SDK with very short auto-validation interval
        let config = LicenseSeatConfig(
            apiBaseUrl: "https://example.com", // value does not matter for stubs
            apiKey: "test-api-key",
            autoValidateInterval: 0.2,
            debug: false
        )
        sdk = LicenseSeat(config: config, urlSession: session)
        
        // Expect at least one autovalidation:cycle event within 1 second
        let fired = expectation(description: "Auto-validation cycle fired")
        var didFulfill = false
        let cancellable = sdk.on("autovalidation:cycle") { _ in
            if !didFulfill {
                didFulfill = true
                fired.fulfill()
            }
        }
        cancellables.insert(cancellable)
        
        // Activate license (starts auto-validation)
        _ = try await sdk.activate(licenseKey: "LIC-TEST")
        
        await fulfillment(of: [fired], timeout: 1.0)
    }
} 