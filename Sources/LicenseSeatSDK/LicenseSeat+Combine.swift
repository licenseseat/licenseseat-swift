//
//  LicenseSeat+Combine.swift
//  LicenseSeatSDK
//
//  Created by LicenseSeat on 2025.
//  Copyright © 2025 LicenseSeat. All rights reserved.
//

import Foundation
#if canImport(Combine)
import Combine

// Publisher and event types are intentionally namespaced under LicenseSeat.
// swiftlint:disable nesting

// MARK: - ObservableObject Conformance

extension LicenseSeat: ObservableObject {}

// MARK: - Combine Publishers

extension LicenseSeat {
    
    /// Publisher for SDK events
    public struct EventPublisher: Publisher {
        public typealias Output = Event
        public typealias Failure = Never
        
        private let eventName: String?
        private let eventBus: EventBus
        
        init(eventName: String? = nil, eventBus: EventBus) {
            self.eventName = eventName
            self.eventBus = eventBus
        }
        
        public func receive<S>(subscriber: S) where S: Subscriber, S.Input == Output, S.Failure == Failure {
            let subscription = EventSubscription(
                subscriber: subscriber,
                eventName: eventName,
                eventBus: eventBus
            )
            subscriber.receive(subscription: subscription)
        }
    }
    
    /// SDK Event type
    public struct Event {
        public let name: String
        public let data: Any
        
        public init(name: String, data: Any) {
            self.name = name
            self.data = data
        }
    }
    
    /// Get a publisher for all events
    public var eventPublisher: EventPublisher {
        EventPublisher(eventBus: eventBus)
    }
    
    /// Get a publisher for specific event
    public func eventPublisher(for eventName: String) -> EventPublisher {
        EventPublisher(eventName: eventName, eventBus: eventBus)
    }
    
    /// Publisher for license status changes
    public var statusPublisher: AnyPublisher<LicenseStatus, Never> {
        eventPublisher
            .compactMap { event in
                switch event.name {
                case "license:loaded",
                     "activation:success", "activation:error",
                     "validation:success", "validation:failed",
                     "validation:offline-success", "validation:offline-failed",
                     "license:revoked",
                     "deactivation:success", "sdk:reset":
                    return self.getStatus()
                default:
                    return nil
                }
            }
            .removeDuplicates()
            .eraseToAnyPublisher()
    }
    
    /// Publisher for entitlement changes
    public func entitlementPublisher(for key: String) -> AnyPublisher<EntitlementStatus, Never> {
        eventPublisher
            .compactMap { event in
                switch event.name {
                case "activation:success",
                     "validation:success", "validation:failed",
                     "validation:offline-success", "validation:offline-failed",
                     "license:revoked", "deactivation:success", "sdk:reset":
                    return self.checkEntitlement(key)
                default:
                    return nil
                }
            }
            .removeDuplicates()
            .eraseToAnyPublisher()
    }
    
    /// Publisher for network status changes
    public var networkStatusPublisher: AnyPublisher<Bool, Never> {
        eventPublisher(for: "network:online")
            .map { _ in true }
            .merge(with: eventPublisher(for: "network:offline").map { _ in false })
            .removeDuplicates()
            .eraseToAnyPublisher()
    }
}

// MARK: - Private Subscription

private final class EventSubscription<S: Subscriber>: Subscription
where S.Input == LicenseSeat.Event, S.Failure == Never {
    private let lock = NSLock()
    private var subscriber: S?
    private let eventName: String?
    private let eventBus: EventBus
    private var eventCancellable: AnyCancellable?
    private var outstandingDemand: Subscribers.Demand = .none
    private var subscribed = false
    
    init(subscriber: S, eventName: String?, eventBus: EventBus) {
        self.subscriber = subscriber
        self.eventName = eventName
        self.eventBus = eventBus
    }
    
    func request(_ newDemand: Subscribers.Demand) {
        guard newDemand > .none else { return }

        lock.lock()
        guard subscriber != nil else {
            lock.unlock()
            return
        }
        outstandingDemand += newDemand
        let shouldSubscribe = !subscribed
        subscribed = true
        lock.unlock()

        guard shouldSubscribe else { return }

        let cancellable: AnyCancellable
        if let eventName {
            cancellable = eventBus.on(eventName) { [weak self] data in
                self?.receive(LicenseSeat.Event(name: eventName, data: data))
            }
        } else {
            cancellable = eventBus.onAny { [weak self] event, data in
                self?.receive(LicenseSeat.Event(name: event, data: data))
            }
        }

        lock.lock()
        if subscriber == nil {
            lock.unlock()
            cancellable.cancel()
        } else {
            eventCancellable = cancellable
            lock.unlock()
        }
    }

    func cancel() {
        lock.lock()
        subscriber = nil
        outstandingDemand = .none
        let cancellable = eventCancellable
        eventCancellable = nil
        lock.unlock()
        cancellable?.cancel()
    }

    private func receive(_ event: LicenseSeat.Event) {
        lock.lock()
        guard outstandingDemand > .none, let subscriber else {
            lock.unlock()
            return
        }
        if outstandingDemand != .unlimited {
            outstandingDemand -= 1
        }
        lock.unlock()

        let additionalDemand = subscriber.receive(event)
        guard additionalDemand > .none else { return }

        lock.lock()
        if self.subscriber != nil {
            outstandingDemand += additionalDemand
        }
        lock.unlock()
    }
}

// MARK: - Convenience Extensions

extension LicenseSeat.Event {
    /// Type-safe event data accessors
    
    public var licenseKey: String? {
        (data as? [String: Any])?["licenseKey"] as? String
    }
    
    public var error: Error? {
        (data as? [String: Any])?["error"] as? Error
    }
    
    public var license: License? {
        data as? License
    }
    
    public var dictionary: [String: Any]? {
        data as? [String: Any]
    }
}

// swiftlint:enable nesting

#endif // canImport(Combine)
