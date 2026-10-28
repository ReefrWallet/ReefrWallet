//
//  AccountFilter.swift
//  Reefr Wallet
//
//  Created by Andrey Yurkevich on 03.11.26.
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import Foundation

/// Mail-style filter: token criteria apply to balances, addressed criteria to transactions.
struct AccountFilter: Codable, Equatable {
    var fromMyAccounts = false
    var hideUnknownTokens = false
    var hideZeroBalances = false
    var toMyAccounts = false

    /// Pill text, e.g. "Non-zero Balances, Known Tokens".
    func summary(in tab: AccountTab) -> String {
        var parts: [String] = []

        if tab == .transactions {
            if toMyAccounts {
                parts.append(String(localized: .accountDetailsPillToMe))
            }

            if fromMyAccounts {
                parts.append(String(localized: .accountDetailsPillFromMe))
            }
        }

        if tab == .balances {
            if hideZeroBalances {
                parts.append(String(localized: .accountDetailsPillNonZeroBalances))
            }

            if hideUnknownTokens {
                parts.append(String(localized: .accountDetailsPillKnownTokens))
            }
        }

        return parts.joined(separator: ", ")
    }

    /// `true` when the filter changes what `tab` lists.
    func isActive(in tab: AccountTab) -> Bool {
        switch tab {
        case .approvals: false
        case .balances: hideZeroBalances || hideUnknownTokens
        case .transactions: toMyAccounts || fromMyAccounts
        }
    }

    /// Criteria applied when the filter button is switched on with nothing selected.
    mutating func enableDefaults(in tab: AccountTab) {
        switch tab {
        case .approvals: break
        case .balances: hideZeroBalances = true
        case .transactions: toMyAccounts = true
        }
    }

    mutating func reset(in tab: AccountTab) {
        switch tab {
        case .approvals:
            break
        case .balances:
            hideZeroBalances = false
            hideUnknownTokens = false
        case .transactions:
            fromMyAccounts = false
            toMyAccounts = false
        }
    }

    var restrictsTransactions: Bool {
        toMyAccounts || fromMyAccounts
    }

    /// Whether `model` passes the transaction filters. `myAddresses` are all accounts' addresses.
    func includes(_ model: TransactionRowModel, myAddresses: Set<String>) -> Bool {
        guard restrictsTransactions else {
            return true
        }

        let recipient = model.recipient?.lowercased()
        let sender = model.sender?.lowercased()

        return (toMyAccounts && recipient.map(myAddresses.contains) == true)
            || (fromMyAccounts && sender.map(myAddresses.contains) == true)
    }

    /// Whether a balance passes the token filters.
    func includes(_ balance: Balance) -> Bool {
        if hideUnknownTokens, balance.token.isHidden {
            return false
        }

        if hideZeroBalances, balance.decimalAmount <= 0 {
            return false
        }

        return true
    }
}

extension AccountFilter {
    /// `@AppStorage` payload.
    var storageString: String {
        (try? asJSONString()) ?? ""
    }

    init(storageString: String) {
        self = (try? storageString.decoded()) ?? AccountFilter()
    }
}
