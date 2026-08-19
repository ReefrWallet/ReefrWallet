//
//  MoralisPageResponse.swift
//  Reefr Wallet
//
//  Created by Andrey Yurkevich on 21.12.25.
//  Copyright © 2025 Reefr Wallet. All rights reserved.
//

struct MoralisPageResponse<T: Decodable>: Decodable {
    let cursor: String?
    let page: UInt?
    let pageSize: UInt?
    let result: [T]?
}
