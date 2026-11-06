//
//  TokenModel.swift
//  Reefr Wallet
//
//  Created by Andrey Yurkevich on 17.01.26.
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import SwiftData
import WalletKit

// MARK: - Token

struct Token: Hashable, Sendable {
    /// CoinType on sui, contract address on Ethereum. `nil` for native token on ethereum.
    let address: String?
    let blockchain: Blockchain?
    var coinGeckoId: String?
    var decimalsCount: UInt8
    /// Whether the most recent price fetch failed; `usdPrice` then holds the last good quote, if any.
    var hasPriceFetchError = false
    var imageURL: URL?
    var isHidden: Bool
    var isIncludedInBalance: Bool?
    let isNativeToken: Bool
    var name: String
    /// The `PriceSource.id` that quoted `usdPrice`; `nil` after a failed fetch.
    var priceSourceId: String?
    /// When a price fetch last completed, successfully or not.
    var priceUpdatedAt: Date?
    var symbol: String
    var usdPrice: Decimal?
}

extension Token: Decodable {
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        address = try container.decodeIfPresent(String.self, forKey: .address)
        blockchain = try container.decode(Blockchain.self, forKey: .blockchain)
        coinGeckoId = try container.decodeIfPresent(String.self, forKey: .coinGeckoId)
        decimalsCount = try container.decode(UInt8.self, forKey: .decimalsCount)
        isNativeToken = try container.decode(Bool.self, forKey: .isNativeToken)
        name = try container.decode(String.self, forKey: .name)
        symbol = try container.decode(String.self, forKey: .symbol)

        isHidden = false
        isIncludedInBalance = true
        imageURL = nil
        usdPrice = nil
    }

    init(address: String?, blockchain: Blockchain, tokenInfo: TokenInfo) {
        self.address = address
        self.blockchain = blockchain
        coinGeckoId = nil
        self.decimalsCount = tokenInfo.decimals
        self.isHidden = false
        self.isNativeToken = tokenInfo.isNative
        self.name = tokenInfo.name
        self.symbol = tokenInfo.symbol
    }

    private enum CodingKeys: String, CodingKey {
        case address
        case blockchain
        case coinGeckoId
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
    /// Guards against duplicate rows when concurrent sync tracks race to discover the
    /// same token: SwiftData upserts into the existing row on a constraint match instead
    /// of inserting a second one.
    #Unique<TokenModel>([\.address, \.blockchain])

    /// `nil` for native tokens
    var address: String?
    var coinGeckoId: String?
    var decimalsCount: UInt8
    var hasPriceFetchError = false
    var imageURL: URL?
    var isIncludedInBalance: Bool?
    var isNativeToken: Bool
    var isWhitelisted: Bool?
    var name: String
    var priceSourceId: String?
    var priceUpdatedAt: Date?
    var symbol: String
    var usdPrice: Decimal?

    @Relationship(deleteRule: .cascade, inverse: \ApprovalModel.token)
    var approvals: [ApprovalModel]? = []

    @Relationship(deleteRule: .cascade, inverse: \BalanceModel.token)
    var balances: [BalanceModel]?

    @Relationship(deleteRule: .noAction, inverse: \BlockchainModel.tokens)
    var blockchain: BlockchainModel?

    init(
        address: String?,
        blockchain: BlockchainModel? = nil,
        coinGeckoId: String? = nil,
        decimalsCount: UInt8,
        imageURL: URL? = nil,
        isNativeToken: Bool,
        name: String,
        symbol: String,
        usdPrice: Decimal? = nil
    ) {
        self.address = address
        self.blockchain = blockchain
        self.coinGeckoId = coinGeckoId
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
        blockchain = model.blockchain?.blockchain
        coinGeckoId = model.coinGeckoId
        decimalsCount = model.decimalsCount
        hasPriceFetchError = model.hasPriceFetchError
        imageURL = model.imageURL
        isHidden = model.isHidden
        isIncludedInBalance = model.isIncludedInBalance
        isNativeToken = model.isNativeToken
        name = model.name
        priceSourceId = model.priceSourceId
        priceUpdatedAt = model.priceUpdatedAt
        symbol = model.symbol
        usdPrice = model.usdPrice
    }
}

extension TokenModel {
    convenience init(from token: Token) {
        self.init(
            address: token.address,
            blockchain: nil,
            coinGeckoId: token.coinGeckoId,
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
    /// Converts a human-readable decimal amount string to this token's
    /// smallest unit as a `BigUInt`.
    ///
    /// Example: `"1.5"` with `decimalsCount = 6` → `BigUInt(1_500_000)`.
    func smallestUnitAmount(from text: String) throws -> BigUInt {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)

        // `Decimal(string:)` stops at the first bad character, so `1,5` alone would read as 1.
        guard
            text.wholeMatch(of: /[0-9]*\.?[0-9]*/) != nil,
            let decimal = Decimal(string: text),
            decimal > 0
        else {
            throw ReefrError.invalidData
        }

        // Scale by 10^decimals without losing integer precision.
        var multiplier = Decimal(1)
        for _ in 0..<decimalsCount { multiplier *= 10 }

        let scaled = NSDecimalNumber(decimal: decimal * multiplier)

        let handler = NSDecimalNumberHandler(
            roundingMode: .down,
            scale: 0,
            raiseOnExactness: false,
            raiseOnOverflow: false,
            raiseOnUnderflow: false,
            raiseOnDivideByZero: false
        )

        let truncated = scaled.rounding(accordingToBehavior: handler)

        // Reject sub-smallest-unit amounts: the scaled value must already be an
        // exact integer. e.g. 0.0000001 USDC (6 decimals) → 0.1 base units → reject.
        guard scaled == truncated else {
            throw ReefrError.invalidData
        }

        guard let amount = BigUInt(truncated.stringValue), amount > 0 else {
            throw ReefrError.invalidData
        }

        return amount
    }
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
