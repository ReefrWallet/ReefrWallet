//
//  TokenModel.swift
//  Reefr Wallet
//
//  Created by Andrey Yurkevich on 17.01.26.
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import Foundation
import SwiftData
import WalletKit

// MARK: - Token

struct Token: Hashable, Sendable {
    /// CoinType on sui, contract address on Ethereum. `nil` for native token on ethereum.
    let address: String?
    let decimalsCount: UInt8
    let imageURL: URL?
    let isHidden: Bool
    let isIncludedInBalance: Bool?
    let isNativeToken: Bool
    let name: String
    let symbol: String
    var usdPrice: Decimal?
}

extension Token: Decodable {
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        address = try container.decodeIfPresent(String.self, forKey: .address)
        decimalsCount = try container.decode(UInt8.self, forKey: .decimalsCount)
        isNativeToken = try container.decode(Bool.self, forKey: .isNativeToken)
        name = try container.decode(String.self, forKey: .name)
        symbol = try container.decode(String.self, forKey: .symbol)

        isHidden = false
        isIncludedInBalance = true
        imageURL = nil
        usdPrice = nil
    }

    private enum CodingKeys: String, CodingKey {
        case address
        case decimalsCount
        case imageURL
        case isNativeToken
        case name
        case symbol
        case usdPrice
    }
}

// MARK: - TokenModel

@Model
final class TokenModel {
    /// `nil` for native tokens
    var address: String?
    var decimalsCount: UInt8
    var imageURL: URL?
    var isIncludedInBalance: Bool?
    var isNativeToken: Bool
    var isWhitelisted: Bool?
    var name: String
    var symbol: String
    var usdPrice: Decimal?

    @Relationship
    var balances: [BalanceModel]?

    @Relationship
    var blockchain: BlockchainModel?

    init(
        address: String?,
        blockchain: BlockchainModel? = nil,
        decimalsCount: UInt8,
        imageURL: URL? = nil,
        isNativeToken: Bool,
        name: String,
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

// MARK: - Init

extension Token {
    init(model: TokenModel) {
        address = model.address
        decimalsCount = model.decimalsCount
        imageURL = model.imageURL
        isHidden = model.isHidden
        isIncludedInBalance = model.isIncludedInBalance
        isNativeToken = model.isNativeToken
        name = model.name
        symbol = model.symbol
        usdPrice = model.usdPrice
    }
}

extension TokenModel {
    convenience init(from token: Token) {
        self.init(
            address: token.address,
            blockchain: nil,
            decimalsCount: token.decimalsCount,
            isNativeToken: token.isNativeToken,
            name: token.name,
            symbol: token.symbol
        )
    }

    convenience init(from tokenInfo: TokenInfo) {
        self.init(
            address: tokenInfo.address,
            decimalsCount: tokenInfo.decimals,
            isNativeToken: tokenInfo.isNative,
            name: tokenInfo.name,
            symbol: tokenInfo.symbol
        )
    }
}

// MARK: - Helpers

extension Token {
}

extension TokenModel {
    var isHidden: Bool {
        usdPrice == nil && !isNativeToken
    }
}

// MARK: - Decodable

extension TokenModel: Decodable {
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
        let symbol = try container.decode(String.self, forKey: .symbol)
        let name = try container.decodeIfPresent(String.self, forKey: .name) ?? "\(symbol) Token"

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
