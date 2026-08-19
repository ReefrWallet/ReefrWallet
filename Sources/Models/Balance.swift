//
//  Balance.swift
//  Reefr Wallet
//
//  Created by Andrey Yurkevich on 17.01.26.
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import BigInt
import Foundation
import SwiftData

// MARK: - Balance Model

@Model
final class Balance: Identifiable, Hashable {
    @Relationship
    var account: Account

    var serializedAmount: Data

    @Relationship
    var token: Token

    init(account: Account, amount: BigUInt, token: Token) {
        self.account = account
        self.serializedAmount = amount.serialize()
        self.token = token
    }
}

// MARK: - Public

extension Balance {
    var amount: BigUInt {
        BigUInt(serializedAmount)
    }

    var decimalAmount: Decimal {
        let amount = BigUInt(serializedAmount)
        let significand = Decimal(amount)
        return Decimal(sign: .plus, exponent: -Int(token.decimalsCount), significand: significand)
    }

    var usdValue: Decimal {
        decimalAmount * (token.usdPrice ?? 0)
    }
}
