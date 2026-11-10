//
//  BrowserAccountSelector.swift
//  Reefr Wallet
//
//  Created by Andrey Yurkevich on 02.10.26.
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import SwiftUI

/// The browser toolbar's read-only account capsule: "Not Connected" until the site is
/// connected, then the connected account ("Key · Account (address)") or, when
/// several are connected, a summary such as "2 accounts (Arbitrum, Solana)".
/// It is not interactive; accounts are changed from the dapp's settings.
struct BrowserAccountSelector: View {
    let connected: [DappAccountChoice]

    var body: some View {
        Text(verbatim: label)
            .style(.medium)
            .lineLimit(1)
            .frame(minWidth: 240, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Capsule().fill(.quaternary))
            .allowsHitTesting(false)
            .accessibilityElement(children: .ignore)
            .accessibilityIdentifier("browser-account-selector")
            .accessibilityLabel(label)
            // macOS toolbars cache the item's accessibility label; a new identity refreshes it.
            .id(label)
    }

    var label: String {
        Self.label(for: connected)
    }

    static func label(for connected: [DappAccountChoice]) -> String {
        switch connected.count {
        case 0:
            return String(localized: .browserAccountSelectorNotConnected)
        case 1:
            return connected[0].label
        default:
            let chains = connected
                .map { $0.account.blockchain.displayName.replacingOccurrences(of: " Mainnet", with: "") }
                .joined(separator: ", ")

            return String(localized: .browserAccountSelectorAccountsOnChains(connected.count, chains))
        }
    }
}
