//
//  BalancesTableEntry.swift
//  ReefrWallet
//
//  Created by Andrey Yurkevich on 17/09/2026.
//  Copyright © 2025 Reefr Wallet. All rights reserved.
//

import SwiftUI

enum BalancesTableEntry: Identifiable {
    case balance(Balance)
    case hiddenBalancesTitle
    case none

    var decimalAmount: Decimal {
        if case let .balance(balance) = self {
            balance.decimalAmount
        } else {
            0
        }
    }

    var displayAmount: String {
        if case .balance = self {
            decimalAmount.formatted(.number)
        } else {
            ""
        }
    }

    var displayName: String {
        switch self {
        case let .balance(balance):
            balance.token.name
        case .hiddenBalancesTitle:
            "Hidden Balances"
        case .none:
            ""
        }
    }

    var displayUSDPrice: String {
        if case .balance = self {
            usdPrice.formatted(.number.precision(.fractionLength(2)))
        } else {
            ""
        }
    }

    var displayUSDValue: String {
        if case .balance = self {
            usdValue.formatted(.number.precision(.fractionLength(2)))
        } else {
            ""
        }
    }

    var id: String {
        if case let .balance(balance) = self, let idString = balance.idString {
            idString
        } else {
            // we don't want this selected, so generate new id each time
            UUID().uuidString
        }
    }

    var isIncludedInBalance: Bool {
        if case let .balance(balance) = self {
            if let isIncludedInBalance = balance.token.isIncludedInBalance {
                return isIncludedInBalance
            } else {
                return !balance.token.isHidden
            }
        } else {
            return false
        }
    }

    var usdPrice: Decimal {
        if case let .balance(balance) = self {
            balance.token.usdPrice ?? 0
        } else {
            0
        }
    }

    var usdValue: Decimal {
        if case let .balance(balance) = self {
            balance.usdValue ?? 0
        } else {
            0
        }
    }
}
