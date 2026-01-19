import XCTest
#if canImport(Combine)
import Combine
#endif
@testable import LicenseSeat

final class EventBusTests: XCTestCase {

    var eventBus: EventBus!
    var cancellables: [AnyCancellable] = []

    override func setUp() {
        super.setUp()
        eventBus = EventBus()
        cancellables = []
    }

    override func tearDown() {
        cancellables.removeAll()
        eventBus = nil
        super.tearDown()
    }

    // MARK: - Basic Subscription Tests

    func testSubscriptionCount() {
        XCTAssertEqual(eventBus.subscriptionCount(for: "test"), 0)

        // Store the cancellable to prevent immediate deallocation
        cancellables.append(eventBus.on("test") { _ in })
        XCTAssertEqual(eventBus.subscriptionCount(for: "test"), 1)

        cancellables.append(eventBus.on("test") { _ in })
        XCTAssertEqual(eventBus.subscriptionCount(for: "test"), 2)
    }

    func testMultipleEventsIndependent() {
        cancellables.append(eventBus.on("event1") { _ in })
        cancellables.append(eventBus.on("event2") { _ in })
        cancellables.append(eventBus.on("event2") { _ in })

        XCTAssertEqual(eventBus.subscriptionCount(for: "event1"), 1)
        XCTAssertEqual(eventBus.subscriptionCount(for: "event2"), 2)
    }

    // MARK: - Cancellation Tests

    func testCancellableRemovesSubscription() {
        let cancellable = eventBus.on("cancel:test") { _ in }

        XCTAssertEqual(eventBus.subscriptionCount(for: "cancel:test"), 1)

        // Cancel the subscription
        cancellable.cancel()

        // Wait a moment for async cancellation
        let expectation = XCTestExpectation(description: "Async cancellation")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) {
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1.0)

        XCTAssertEqual(eventBus.subscriptionCount(for: "cancel:test"), 0)
    }

    func testMultipleCancellablesIndependent() {
        let cancellable1 = eventBus.on("independent") { _ in }
        let cancellable2 = eventBus.on("independent") { _ in }

        XCTAssertEqual(eventBus.subscriptionCount(for: "independent"), 2)

        // Cancel first subscription
        cancellable1.cancel()

        // Wait for async cancellation
        let wait1 = XCTestExpectation(description: "Wait")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { wait1.fulfill() }
        wait(for: [wait1], timeout: 1.0)

        XCTAssertEqual(eventBus.subscriptionCount(for: "independent"), 1)

        // Cancel second subscription
        cancellable2.cancel()

        let wait2 = XCTestExpectation(description: "Wait2")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { wait2.fulfill() }
        wait(for: [wait2], timeout: 1.0)

        XCTAssertEqual(eventBus.subscriptionCount(for: "independent"), 0)
    }

    // MARK: - Bulk Removal Tests

    func testRemoveAllSubscriptionsForEvent() {
        cancellables.append(eventBus.on("bulk") { _ in })
        cancellables.append(eventBus.on("bulk") { _ in })
        cancellables.append(eventBus.on("other") { _ in })

        XCTAssertEqual(eventBus.subscriptionCount(for: "bulk"), 2)
        XCTAssertEqual(eventBus.subscriptionCount(for: "other"), 1)

        eventBus.removeAllSubscriptions(for: "bulk")

        // Wait for async removal
        let wait = XCTestExpectation(description: "Wait")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { wait.fulfill() }
        self.wait(for: [wait], timeout: 1.0)

        XCTAssertEqual(eventBus.subscriptionCount(for: "bulk"), 0)
        XCTAssertEqual(eventBus.subscriptionCount(for: "other"), 1)
    }

    func testRemoveAllSubscriptions() {
        cancellables.append(eventBus.on("event1") { _ in })
        cancellables.append(eventBus.on("event2") { _ in })

        XCTAssertEqual(eventBus.subscriptionCount(for: "event1"), 1)
        XCTAssertEqual(eventBus.subscriptionCount(for: "event2"), 1)

        eventBus.removeAllSubscriptions()

        // Wait for async removal
        let wait = XCTestExpectation(description: "Wait")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { wait.fulfill() }
        self.wait(for: [wait], timeout: 1.0)

        XCTAssertEqual(eventBus.subscriptionCount(for: "event1"), 0)
        XCTAssertEqual(eventBus.subscriptionCount(for: "event2"), 0)
    }

    // MARK: - Deallocation Tests

    func testCancellableDeallocationTriggersCancellation() {
        var cancellable: AnyCancellable? = eventBus.on("dealloc:test") { _ in }

        XCTAssertEqual(eventBus.subscriptionCount(for: "dealloc:test"), 1)

        // Deallocate the cancellable
        cancellable = nil

        // Wait for async cancellation
        let wait = XCTestExpectation(description: "Wait")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { wait.fulfill() }
        self.wait(for: [wait], timeout: 1.0)

        XCTAssertEqual(eventBus.subscriptionCount(for: "dealloc:test"), 0)
    }
}
