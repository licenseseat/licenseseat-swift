import XCTest
#if canImport(Combine)
import Combine
#endif
@testable import LicenseSeat

final class EventBusTests: LicenseSeatTestCase {

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

    func testAnyEventSubscriptionReceivesUnknownFutureEventName() {
        let received = expectation(description: "all-event handler")
        let cancellable = eventBus.onAny { name, payload in
            XCTAssertEqual(name, "future:event-added-after-release")
            XCTAssertEqual(payload as? Int, 42)
            received.fulfill()
        }

        eventBus.emit("future:event-added-after-release", 42)

        wait(for: [received], timeout: 1)
        cancellable.cancel()
    }

    func testEmissionsAreDeliveredInOrder() {
        let received = expectation(description: "ordered delivery")
        received.expectedFulfillmentCount = 3
        var values: [Int] = []
        let cancellable = eventBus.on("ordered") { payload in
            values.append(payload as! Int)
            received.fulfill()
        }

        eventBus.emit("ordered", 1)
        eventBus.emit("ordered", 2)
        eventBus.emit("ordered", 3)

        wait(for: [received], timeout: 1)
        XCTAssertEqual(values, [1, 2, 3])
        cancellable.cancel()
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
        XCTAssertNotNil(cancellable)

        // Deallocate the cancellable
        cancellable = nil

        // Wait for async cancellation
        let wait = XCTestExpectation(description: "Wait")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { wait.fulfill() }
        self.wait(for: [wait], timeout: 1.0)

        XCTAssertEqual(eventBus.subscriptionCount(for: "dealloc:test"), 0)
    }
}

#if canImport(Combine)
@MainActor
final class CombineDemandTests: LicenseSeatTestCase {
    func testEventPublisherHonorsFiniteSubscriberDemand() async {
        let config = LicenseSeatConfig(
            productSlug: "demand-test",
            storagePrefix: "combine_demand_\(UUID().uuidString)_",
            autoValidateInterval: 0,
            heartbeatInterval: 0,
            offlineTokenRefreshInterval: 0
        )
        let seat = LicenseSeat(config: config)
        await seat.waitForInitialization()

        let firstValue = expectation(description: "first demanded value")
        let secondValue = expectation(description: "second demanded value")
        let subscriber = FiniteDemandSubscriber { value in
            if value == 1 {
                firstValue.fulfill()
            } else if value == 3 {
                secondValue.fulfill()
            }
        }
        defer {
            subscriber.cancel()
            seat.reset()
        }

        seat.eventPublisher(for: "demand:test").receive(subscriber: subscriber)
        seat.eventBus.emit("demand:test", 1)
        seat.eventBus.emit("demand:test", 2)

        await assertFulfillment(of: [firstValue], timeout: 1)
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(subscriber.values, [1], "Values without demand must be dropped")

        subscriber.requestOne()
        seat.eventBus.emit("demand:test", 3)

        await assertFulfillment(of: [secondValue], timeout: 1)
        XCTAssertEqual(subscriber.values, [1, 3])
    }
}

private final class FiniteDemandSubscriber: Subscriber {
    typealias Input = LicenseSeat.Event
    typealias Failure = Never

    private let lock = NSLock()
    private let onValue: (Int) -> Void
    private var subscription: Subscription?
    private var receivedValues: [Int] = []

    init(onValue: @escaping (Int) -> Void) {
        self.onValue = onValue
    }

    var values: [Int] {
        lock.lock()
        defer { lock.unlock() }
        return receivedValues
    }

    func receive(subscription: Subscription) {
        lock.lock()
        self.subscription = subscription
        lock.unlock()
        subscription.request(.max(1))
    }

    func receive(_ input: LicenseSeat.Event) -> Subscribers.Demand {
        guard let value = input.data as? Int else { return .none }
        lock.lock()
        receivedValues.append(value)
        lock.unlock()
        onValue(value)
        return .none
    }

    func receive(completion: Subscribers.Completion<Never>) {}

    func requestOne() {
        lock.lock()
        let subscription = subscription
        lock.unlock()
        subscription?.request(.max(1))
    }

    func cancel() {
        lock.lock()
        let subscription = subscription
        self.subscription = nil
        lock.unlock()
        subscription?.cancel()
    }
}
#endif
