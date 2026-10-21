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

    /// Stable per-token hook for UI tests, e.g. `balance-amount-USDC`.
    var amountAccessibilityIdentifier: String {
        if case let .balance(balance) = self {
            "balance-amount-\(balance.token.symbol)"
        } else {
            ""
        }
    }

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
        switch self {
        case let .balance(balance):
            // we don't want this selected, so generate new id each time
            balance.idString ?? UUID().uuidString
        case .hiddenBalancesTitle:
            "hidden-balances-title"
        case .none:
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

    /// Tokens.xcassets icon name for the token's symbol, if the catalog has one.
    var tokenImageName: String? {
        guard case let .balance(balance) = self else {
            return nil
        }

        let name = "\(balance.token.symbol.lowercased())Token16"
        #if os(macOS)
        return NSImage(named: name) == nil ? nil : name
        #else
        return UIImage(named: name) == nil ? nil : name
        #endif
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
