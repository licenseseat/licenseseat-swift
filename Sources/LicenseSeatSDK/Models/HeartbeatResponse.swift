//
//  HeartbeatResponse.swift
//  LicenseSeatSDK
//
//  Created by LicenseSeat on 2025.
//  Copyright © 2025 LicenseSeat. All rights reserved.
//

import Foundation

struct HeartbeatResponse: Codable, Equatable, Sendable {
    let object: String
    let receivedAt: Date
    let license: LicenseResponse?

    enum CodingKeys: String, CodingKey {
        case object
        case receivedAt = "received_at"
        case license
    }
}
