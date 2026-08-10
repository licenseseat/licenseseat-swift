//
//  EventBus.swift
//  LicenseSeatSDK
//
//  Created by LicenseSeat on 2025.
//  Copyright © 2025 LicenseSeat. All rights reserved.
//

import Foundation

#if canImport(Combine)
import Combine
#else
/// Minimal Combine-compatible cancellable type for platforms without Combine.
public final class AnyCancellable: Hashable, @unchecked Sendable {
    private let id = UUID()
    private let lock = NSLock()
    private var cancelHandler: (() -> Void)?

    public init(_ cancel: @escaping () -> Void = {}) {
        self.cancelHandler = cancel
    }

    public func cancel() {
        lock.lock()
        let handler = cancelHandler
        cancelHandler = nil
        lock.unlock()
        handler?()
    }

    public func store(in set: inout Set<AnyCancellable>) {
        set.insert(self)
    }

    deinit {
        cancel()
    }

    // Hashable
    public static func == (lhs: AnyCancellable, rhs: AnyCancellable) -> Bool {
        lhs.id == rhs.id
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}
#endif

/// A unique identifier for event subscriptions
typealias SubscriptionID = UInt64

/// An event handler with its unique subscription ID
private struct EventHandler: @unchecked Sendable {
    let id: SubscriptionID
    let handler: (Any) -> Void
}

/// Handler used by the unfiltered Combine event publisher.
private struct AnyEventHandler: @unchecked Sendable {
    let id: SubscriptionID
    let handler: (String, Any) -> Void
}

/// Bridges the intentionally type-erased public event API across dispatch
/// queues. EventBus serializes access and invokes handlers on the main queue;
/// the wrapper prevents Swift from assuming arbitrary payloads are otherwise
/// safe to share concurrently.
private struct EventPayload: @unchecked Sendable {
    let value: Any
}

/// Event bus for SDK events
///
/// Provides a thread-safe publish/subscribe mechanism for SDK events.
/// Uses a token-based subscription system for reliable unsubscription.
final class EventBus: @unchecked Sendable {
    /// Maps event names to their handlers
    private var listeners: [String: [EventHandler]] = [:]

    /// Subscribers interested in every event, including future event names.
    private var anyEventListeners: [AnyEventHandler] = []

    /// Serial queue provides thread-safe state access and preserves lifecycle
    /// event ordering for subscribers.
    private let queue = DispatchQueue(label: "com.licenseseat.sdk.eventbus")

    /// Counter for generating unique subscription IDs
    private var nextSubscriptionID: SubscriptionID = 0

    /// Generate a unique subscription ID (must be called on `queue`)
    private func generateSubscriptionID() -> SubscriptionID {
        nextSubscriptionID &+= 1
        return nextSubscriptionID
    }

    /// Subscribe to an event
    ///
    /// - Parameters:
    ///   - event: The event name to subscribe to
    ///   - handler: The closure to call when the event is emitted
    /// - Returns: A cancellable that removes the subscription when cancelled
    @discardableResult
    func on(_ event: String, handler: @escaping (Any) -> Void) -> AnyCancellable {
        var subscriptionID: SubscriptionID = 0

        queue.sync {
            subscriptionID = generateSubscriptionID()
            let eventHandler = EventHandler(id: subscriptionID, handler: handler)

            if self.listeners[event] == nil {
                self.listeners[event] = []
            }
            self.listeners[event]?.append(eventHandler)
        }

        // Return cancellable that removes the handler by ID
        return AnyCancellable { [weak self] in
            self?.removeSubscription(event: event, subscriptionID: subscriptionID)
        }
    }

    /// Subscribe to every event without maintaining a second, drift-prone list
    /// of known event names in the Combine adapter.
    @discardableResult
    func onAny(handler: @escaping (String, Any) -> Void) -> AnyCancellable {
        var subscriptionID: SubscriptionID = 0

        queue.sync {
            subscriptionID = generateSubscriptionID()
            anyEventListeners.append(AnyEventHandler(id: subscriptionID, handler: handler))
        }

        return AnyCancellable { [weak self] in
            self?.removeAnyEventSubscription(subscriptionID: subscriptionID)
        }
    }

    /// Remove a subscription by its ID
    ///
    /// - Parameters:
    ///   - event: The event name
    ///   - subscriptionID: The unique subscription ID to remove
    private func removeSubscription(event: String, subscriptionID: SubscriptionID) {
        queue.sync {
            guard var handlers = self.listeners[event] else { return }

            // Remove handler by subscription ID
            handlers.removeAll { $0.id == subscriptionID }

            if handlers.isEmpty {
                self.listeners[event] = nil
            } else {
                self.listeners[event] = handlers
            }
        }
    }

    private func removeAnyEventSubscription(subscriptionID: SubscriptionID) {
        queue.sync {
            self.anyEventListeners.removeAll { $0.id == subscriptionID }
        }
    }

    /// Remove all subscriptions for a specific event
    ///
    /// - Parameter event: The event name to clear subscriptions for
    func removeAllSubscriptions(for event: String) {
        queue.sync {
            self.listeners[event] = nil
        }
    }

    /// Remove all subscriptions for all events
    func removeAllSubscriptions() {
        queue.sync {
            self.listeners.removeAll()
            self.anyEventListeners.removeAll()
        }
    }

    /// Emit an event
    ///
    /// - Parameters:
    ///   - event: The event name to emit
    ///   - data: The data to pass to handlers
    func emit(_ event: String, _ data: Any) {
        let payload = EventPayload(value: data)
        queue.async { [weak self] in
            guard let self else { return }
            let handlers = self.listeners[event] ?? []
            let anyEventHandlers = self.anyEventListeners

            for eventHandler in handlers {
                DispatchQueue.main.async {
                    eventHandler.handler(payload.value)
                }
            }

            for eventHandler in anyEventHandlers {
                DispatchQueue.main.async {
                    eventHandler.handler(event, payload.value)
                }
            }
        }
    }

    /// Get the number of active subscriptions for an event (for testing)
    func subscriptionCount(for event: String) -> Int {
        var count = 0
        queue.sync {
            count = self.listeners[event]?.count ?? 0
        }
        return count
    }
}
