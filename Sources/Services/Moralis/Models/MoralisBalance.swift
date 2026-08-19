//
//  MoralisBalance.swift
//  Reefr Wallet
//
//  Created by Andrey Yurkevich on 21.12.25.
//  Copyright © 2025 Reefr Wallet. All rights reserved.
//

import BigInt
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

extension Token {
    convenience init(from balance: MoralisBalance) throws {
        self.init(
            address: balance.tokenAddress,
            blockchain: nil,
            decimalsCount: balance.decimals,
            isNativeToken: balance.nativeToken,
            name: balance.name,
            symbol: balance.symbol
        )
    }
}

extension Balance {
    convenience init(from balance: MoralisBalance, account: Account, token: Token) throws {
        guard let amount = BigUInt(balance.balance) else {
            assertionFailure("Cannot convert balance string \"\(balance.balance)\" to BigUInt")
            throw Error.invalidData
        }

        self.init(account: account, amount: amount, token: token)
    }
}
