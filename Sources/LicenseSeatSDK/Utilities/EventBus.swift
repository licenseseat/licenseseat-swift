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

/// Event bus for SDK events
final class EventBus: @unchecked Sendable {
    private var listeners: [String: [(Any) -> Void]] = [:]
    private let queue = DispatchQueue(label: "com.licenseseat.sdk.eventbus", attributes: .concurrent)
    
    /// Subscribe to an event
    @discardableResult
    func on(_ event: String, handler: @escaping (Any) -> Void) -> AnyCancellable {
        queue.async(flags: .barrier) {
            if self.listeners[event] == nil {
                self.listeners[event] = []
            }
            self.listeners[event]?.append(handler)
        }
        
        // Return cancellable that removes the handler
        return AnyCancellable { [weak self] in
            self?.off(event, handler: handler)
        }
    }
    
    /// Unsubscribe from an event
    func off(_ event: String, handler: @escaping (Any) -> Void) {
        queue.async(flags: .barrier) {
            guard var handlers = self.listeners[event] else { return }
            
            // Remove handler by pointer comparison
            handlers.removeAll { existingHandler in
                var isSame = false
                withUnsafePointer(to: existingHandler) { p1 in
                    withUnsafePointer(to: handler) { p2 in
                        isSame = p1 == p2
                    }
                }
                return isSame
            }
            
            if handlers.isEmpty {
                self.listeners[event] = nil
            } else {
                self.listeners[event] = handlers
            }
        }
    }
    
    /// Emit an event
    func emit(_ event: String, _ data: Any) {
        queue.async { [weak self] in
            guard let handlers = self?.listeners[event] else { return }
            
            for handler in handlers {
                DispatchQueue.main.async {
                    handler(data)
                }
            }
        }
    }
} 