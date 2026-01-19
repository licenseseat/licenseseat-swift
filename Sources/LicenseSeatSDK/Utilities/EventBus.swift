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
public struct AnyCancellable: Hashable {
    private static var counter: UInt = 0
    private let id: UInt
    private let cancelHandler: () -> Void

    public init(_ cancel: @escaping () -> Void = {}) {
        Self.counter &+= 1
        self.id = Self.counter
        self.cancelHandler = cancel
    }

    public func cancel() {
        cancelHandler()
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
private struct EventHandler {
    let id: SubscriptionID
    let handler: (Any) -> Void
}

/// Event bus for SDK events
///
/// Provides a thread-safe publish/subscribe mechanism for SDK events.
/// Uses a token-based subscription system for reliable unsubscription.
final class EventBus: @unchecked Sendable {
    /// Maps event names to their handlers
    private var listeners: [String: [EventHandler]] = [:]

    /// Concurrent queue for thread-safe access
    private let queue = DispatchQueue(label: "com.licenseseat.sdk.eventbus", attributes: .concurrent)

    /// Counter for generating unique subscription IDs
    private var nextSubscriptionID: SubscriptionID = 0

    /// Generate a unique subscription ID (must be called within barrier)
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

        queue.sync(flags: .barrier) {
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

    /// Remove a subscription by its ID
    ///
    /// - Parameters:
    ///   - event: The event name
    ///   - subscriptionID: The unique subscription ID to remove
    private func removeSubscription(event: String, subscriptionID: SubscriptionID) {
        queue.async(flags: .barrier) {
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

    /// Unsubscribe from an event (legacy method, prefer using the returned AnyCancellable)
    ///
    /// - Note: This method is deprecated. Use the `AnyCancellable` returned from `on(_:handler:)` instead.
    ///   Closure comparison is unreliable in Swift. This method now does nothing.
    @available(*, deprecated, message: "Use the AnyCancellable returned from on(_:handler:) to unsubscribe")
    func off(_ event: String, handler: @escaping (Any) -> Void) {
        // No-op: Closure comparison doesn't work reliably in Swift.
        // Users should use the AnyCancellable returned from on() to unsubscribe.
    }

    /// Remove all subscriptions for a specific event
    ///
    /// - Parameter event: The event name to clear subscriptions for
    func removeAllSubscriptions(for event: String) {
        queue.async(flags: .barrier) {
            self.listeners[event] = nil
        }
    }

    /// Remove all subscriptions for all events
    func removeAllSubscriptions() {
        queue.async(flags: .barrier) {
            self.listeners.removeAll()
        }
    }

    /// Emit an event
    ///
    /// - Parameters:
    ///   - event: The event name to emit
    ///   - data: The data to pass to handlers
    func emit(_ event: String, _ data: Any) {
        queue.async { [weak self] in
            guard let handlers = self?.listeners[event] else { return }

            for eventHandler in handlers {
                DispatchQueue.main.async {
                    eventHandler.handler(data)
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
