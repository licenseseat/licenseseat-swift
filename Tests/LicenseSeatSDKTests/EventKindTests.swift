//
//  EventKindTests.swift
//  LicenseSeatSDKTests
//
//  #10: a typed enum over the string event bus.
//

import XCTest
#if canImport(Combine)
import Combine
#endif
@testable import LicenseSeat

@MainActor
final class EventKindTests: LicenseSeatTestCase {
    private func makeSDK() -> LicenseSeat {
        LicenseSeat(config: LicenseSeatConfig(storagePrefix: "event_kind_test_\(UUID().uuidString)_"))
    }

    private func waitUntil(_ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(5)
        while !condition(), Date() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    func testWireNamesAreUniqueAndWellFormed() async {
        let names = EventKind.allCases.map(\.rawValue)
        XCTAssertEqual(Set(names).count, names.count)
        for name in names {
            XCTAssertNotNil(
                name.range(of: "^[a-z][A-Za-z]*:[a-z][A-Za-z-]*$", options: .regularExpression),
                name
            )
        }
        // The nine names the 0.5.0 parity audit found undocumented are typed.
        for name in [
            "validation:auth-failed", "validation:auto-failed",
            "offlineToken:fetching", "offlineToken:fetched", "offlineToken:fetchError",
            "offlineToken:ready", "deactivation:start", "sdk:error", "autovalidation:stopped"
        ] {
            XCTAssertNotNil(EventKind(rawValue: name), name)
        }
    }

    func testTypedAndStringSubscriptionsObserveTheSameEvents() async {
        let sdk = makeSDK()
        defer { sdk.shutdown() }
        var typed: [Int] = []
        var stringly: [Int] = []
        let a = sdk.on(.heartbeatSuccess) { typed.append($0 as? Int ?? -1) }
        let b = sdk.on("heartbeat:success") { stringly.append($0 as? Int ?? -1) }
        defer { a.cancel(); b.cancel() }

        sdk.eventBus.emit(.heartbeatSuccess, 1)
        sdk.eventBus.emit("heartbeat:success", 2)
        await waitUntil { typed.count == 2 && stringly.count == 2 }

        XCTAssertEqual(typed, [1, 2])
        XCTAssertEqual(stringly, [1, 2])
    }

    #if canImport(Combine)
    func testTypedPublisherAndEventKind() async {
        let sdk = makeSDK()
        defer { sdk.shutdown() }
        var received: [LicenseSeat.Event] = []
        var all: [EventKind?] = []
        var bag = Set<Combine.AnyCancellable>()
        sdk.eventPublisher(for: .licenseRevoked).sink { received.append($0) }.store(in: &bag)
        sdk.eventPublisher.sink { all.append($0.kind) }.store(in: &bag)

        sdk.eventBus.emit(.licenseRevoked, ["code": "revoked"])
        sdk.eventBus.emit("future:event", 0)
        await waitUntil { received.count == 1 && all.count == 2 }

        XCTAssertEqual(received.map(\.kind), [.licenseRevoked])
        XCTAssertEqual(received.first?.dictionary?["code"] as? String, "revoked")
        XCTAssertEqual(Set(all.map { $0?.rawValue ?? "unknown" }), ["license:revoked", "unknown"])
    }
    #endif

    /// Every SDK emit site uses a typed kind, and every kind is emitted
    /// somewhere, so the enum, the docs, and the code cannot drift apart.
    func testSDKEmitsOnlyTypedKindsAndEveryKindIsEmitted() async throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/LicenseSeatSDK")
        guard let enumerator = FileManager.default.enumerator(
            at: sources,
            includingPropertiesForKeys: nil
        ) else {
            throw XCTSkip("SDK sources are not available next to the tests")
        }
        var code = ""
        for case let url as URL in enumerator.allObjects where url.pathExtension == "swift" {
            code += try String(contentsOf: url, encoding: .utf8)
        }
        XCTAssertFalse(code.isEmpty)
        XCTAssertNil(code.range(of: #"eventBus\.emit\(""#, options: .regularExpression),
                     "SDK code must emit typed EventKind cases")
        for kind in EventKind.allCases {
            XCTAssertNotNil(
                code.range(of: "emit(.\(kind))", options: .literal) ??
                    code.range(of: "emit(.\(kind),", options: .literal),
                "\(kind) is documented but never emitted"
            )
        }
    }
}
