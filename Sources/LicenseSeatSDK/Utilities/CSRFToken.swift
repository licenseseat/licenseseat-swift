//
//  CSRFToken.swift
//  LicenseSeatSDK
//
//  Created by LicenseSeat on 2025.
//  Copyright © 2025 LicenseSeat. All rights reserved.
//

import Foundation
#if canImport(WebKit)
import WebKit
#endif

/// CSRF Token helper for web environments
public enum CSRFToken {
    
    /// Get CSRF token from meta tag (for web-based environments)
    /// - Returns: CSRF token if available
    public static func getToken() -> String? {
        #if os(macOS) || os(iOS)
        // In a web view context, we'd evaluate JavaScript
        // This is a placeholder for the pattern
        return getTokenFromWebView()
        #else
        return nil
        #endif
    }
    
    #if canImport(WebKit)
    private static func getTokenFromWebView() -> String? {
        // This would need to be called from a WKWebView context
        // Example implementation pattern:
        /*
        webView.evaluateJavaScript("""
            document.querySelector('meta[name="csrf-token"]')?.content
        """) { result, error in
            // Handle result
        }
        */
        return nil
    }
    #endif
    
    /// Add CSRF token to headers if available
    /// - Parameter headers: Existing headers dictionary
    /// - Returns: Updated headers with CSRF token if found
    public static func addToHeaders(_ headers: [String: String]) -> [String: String] {
        var updatedHeaders = headers
        
        if let token = getToken() {
            updatedHeaders["X-CSRF-Token"] = token
        }
        
        return updatedHeaders
    }
} 