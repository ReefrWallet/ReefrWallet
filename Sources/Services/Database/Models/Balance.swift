//
//  BalanceModel.swift
//  Reefr Wallet
//
//  Created by Andrey Yurkevich on 17.01.26.
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import BigInt
import Foundation
import SwiftData

// MARK: - Balance

struct Balance: Equatable, Hashable, Identifiable, Sendable {
    let account: Account
    var amount: BigUInt
    /// `Decimal(amount)` shifted by the token's decimals count. Computed once
    /// here instead of on every access - it's read by the table's sort
    /// comparator on every comparison of every sort, and the BigUInt->Decimal
    /// conversion isn't cheap.
    let decimalAmount: Decimal
    let id: PersistentIdentifier?
    /// `"\(id)"`, computed once here instead of on every SwiftUI diff pass.
    let idString: String?
    let token: Token
    let usdValue: Decimal?

    init(account: Account, amount: BigUInt, token: Token, usdValue: Decimal?) {
        self.account = account
        self.amount = amount
        self.token = token
        self.usdValue = usdValue
        id = nil
        idString = nil
        decimalAmount = Decimal(sign: .plus, exponent: -Int(token.decimalsCount), significand: Decimal(amount))
    }
}

// MARK: - BalanceModel

@Model
final class BalanceModel: Identifiable {
    var serializedAmount: Data

    @Relationship(deleteRule: .noAction)
    var account: AccountModel

    @Relationship
    var token: TokenModel

    init(account: AccountModel, amount: BigUInt, token: TokenModel) {
        self.account = account
        self.serializedAmount = amount.serialize()
        self.token = token
    }
}

// MARK: - Init

extension Balance {
    init(model: BalanceModel) throws {
        amount = model.amount
        account = try Account(model: model.account)
        id = model.id
        idString = "\(model.id)"
        token = Token(model: model.token)
        usdValue = model.usdValue
        decimalAmount = Decimal(sign: .plus, exponent: -Int(token.decimalsCount), significand: Decimal(amount))
    }
}

extension BalanceModel {
    var amount: BigUInt {
        get { BigUInt(serializedAmount) }
        set { serializedAmount = newValue.serialize() }
    }

    var decimalAmount: Decimal {
        let significand = Decimal(amount)
        return Decimal(sign: .plus, exponent: -Int(token.decimalsCount), significand: significand)
    }

    var usdValue: Decimal {
        decimalAmount * (token.usdPrice ?? 0)
    }
}
