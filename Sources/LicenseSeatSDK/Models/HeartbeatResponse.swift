//
//  HeartbeatResponse.swift
//  LicenseSeatSDK
//
//  Created by LicenseSeat on 2025.
//  Copyright © 2025 LicenseSeat. All rights reserved.
//

import Foundation

/// The server's acknowledgement of a heartbeat.
public struct HeartbeatResponse: Codable, Equatable, Sendable {
    /// Always `"heartbeat"`.
    public let object: String
    /// When the server recorded the heartbeat.
    public let receivedAt: Date
    /// The license as the server sees it, when included.
    public let license: LicenseResponse?

    enum CodingKeys: String, CodingKey {
        case object
        case receivedAt = "received_at"
        case license
    }
}
