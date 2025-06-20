//
//  EventBus.swift
//  LicenseSeatSDK
//
//  Created by LicenseSeat on 2025.
//  Copyright © 2025 LicenseSeat. All rights reserved.
//

import Foundation
import Combine

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