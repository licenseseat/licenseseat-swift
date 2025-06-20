//
//  LicenseSeat+Combine.swift
//  LicenseSeatSDK
//
//  Created by LicenseSeat on 2025.
//  Copyright © 2025 LicenseSeat. All rights reserved.
//

import Foundation
import Combine

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
                case "activation:success", "activation:error",
                     "validation:success", "validation:failed",
                     "validation:offline-success", "validation:offline-failed",
                     "deactivation:success":
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
                case "validation:success", "validation:offline-success":
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

private final class EventSubscription<S: Subscriber>: Subscription where S.Input == LicenseSeat.Event, S.Failure == Never {
    private var subscriber: S?
    private let eventName: String?
    private let eventBus: EventBus
    private var cancellables: Set<AnyCancellable> = []
    
    init(subscriber: S, eventName: String?, eventBus: EventBus) {
        self.subscriber = subscriber
        self.eventName = eventName
        self.eventBus = eventBus
    }
    
    func request(_ demand: Subscribers.Demand) {
        guard demand > .none else { return }
        
        if let eventName = eventName {
            // Subscribe to specific event
            eventBus.on(eventName) { [weak self] data in
                _ = self?.subscriber?.receive(LicenseSeat.Event(name: eventName, data: data))
            }.store(in: &cancellables)
        } else {
            // Subscribe to all events
            let allEvents = [
                "license:loaded",
                "activation:start", "activation:success", "activation:error",
                "deactivation:start", "deactivation:success", "deactivation:error",
                "validation:start", "validation:success", "validation:failed",
                "validation:error", "validation:auto-failed",
                "validation:offline-success", "validation:offline-failed",
                "validation:auth-failed",
                "autovalidation:cycle", "autovalidation:stopped",
                "network:online", "network:offline",
                "offlineLicense:fetching", "offlineLicense:fetched",
                "offlineLicense:fetchError", "offlineLicense:ready",
                "offlineLicense:verified", "offlineLicense:verificationFailed",
                "auth_test:start", "auth_test:success", "auth_test:error",
                "sdk:error", "sdk:reset"
            ]
            
            for event in allEvents {
                eventBus.on(event) { [weak self] data in
                    _ = self?.subscriber?.receive(LicenseSeat.Event(name: event, data: data))
                }.store(in: &cancellables)
            }
        }
    }
    
    func cancel() {
        subscriber = nil
        cancellables.removeAll()
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