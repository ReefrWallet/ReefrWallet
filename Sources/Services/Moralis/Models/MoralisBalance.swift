//
//  MoralisBalance.swift
//  Reefr Wallet
//
//  Created by Andrey Yurkevich on 21.12.25.
//  Copyright © 2025 Reefr Wallet. All rights reserved.
//

import Foundation

struct MoralisBalance: Decodable {
    let tokenAddress: String
    let balance: String
    let decimals: UInt8
    let logo: URL?
    let name: String
    let nativeToken: Bool
    let possibleSpam: Bool?
    let symbol: String
    let usdPrice: Double?
    let verifiedContract: Bool?
}
