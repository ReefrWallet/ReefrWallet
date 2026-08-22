//
//  Token.swift
//  Reefr Wallet
//
//  Created by Andrey Yurkevich on 17.01.26.
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import Foundation
import SwiftData

// MARK: - Token Model

@Model
final class Token {
    /// `nil` for native tokens
    var address: String?
    var decimalsCount: UInt8
    var imageURL: URL?
    var isIncludedInBalance: Bool?
    var isNativeToken: Bool
    var isWhitelisted: Bool?
    var name: String?
    var symbol: String
    var usdPrice: Decimal?

    @Relationship
    var balances: [Balance]?

    @Relationship
    var blockchain: BlockchainConfig?

    init(
        address: String?,
        blockchain: BlockchainConfig?,
        decimalsCount: UInt8,
        imageURL: URL? = nil,
        isNativeToken: Bool,
        name: String?,
        symbol: String,
        usdPrice: Decimal? = nil
    ) {
        self.address = address
        self.blockchain = blockchain
        self.decimalsCount = decimalsCount
        self.imageURL = imageURL
        self.isNativeToken = isNativeToken
        self.name = name
        self.symbol = symbol
        self.usdPrice = usdPrice

        self.balances = []
    }
}

// MARK: - Helpers

extension Token {
    var isHidden: Bool {
        usdPrice == nil && !isNativeToken
    }
}

// MARK: - Decodable

extension Token: Decodable {
    private enum CodingKeys: String, CodingKey {
        case address
        case decimalsCount
        case isNativeToken
        case name
        case symbol
    }

    convenience init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        let address = try container.decodeIfPresent(String.self, forKey: .address)
        let decimalsCount = try container.decode(UInt8.self, forKey: .decimalsCount)
        let isNativeToken = try container.decode(Bool.self, forKey: .isNativeToken)
        let name = try container.decodeIfPresent(String.self, forKey: .name)
        let symbol = try container.decode(String.self, forKey: .symbol)

        self.init(
            address: address,
            blockchain: nil,
            decimalsCount: decimalsCount,
            isNativeToken: isNativeToken,
            name: name,
            symbol: symbol
        )
    }
}
