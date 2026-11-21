//
//  AccountDefiView.swift
//  Reefr Wallet
//
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import SwiftUI

/// The DeFi tab: one section per plugin kind, read from stored records.
struct AccountDefiView: View {
    let model: AccountDefiModel

    var body: some View {
        #if os(iOS)
        AccountCountLabel(text: totalText)
            .opacity(model.isLoaded ? 1 : 0)
            .accessibilityIdentifier("account-defi-total")

        if model.partlyUnpricedCount > 0 {
            AccountCountLabel(text: String(localized: .defiPartlyUnpriced(model.partlyUnpricedCount)))
        }

        if model.isLoaded, model.positions.isEmpty {
            AccountEmptyRow(title: .defiNoPositions)
                .accessibilityIdentifier("account-no-defi")
        } else {
            ForEach(model.kinds, id: \.self) { kind in
                kind.section(model.positions(of: kind), blockchain: model.account.blockchain)
            }
        }
        #else
        content
            .statusBar(edge: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 4) {
                        Text(.commonTotalValueLabel)
                        Text(verbatim: totalText)
                            .accessibilityIdentifier("account-defi-total")
                    }
                    .opacity(model.isLoaded ? 1 : 0)
                    .style(.mediumHeader, foreground: .primary)

                    if model.partlyUnpricedCount > 0 {
                        Text(.defiPartlyUnpriced(model.partlyUnpricedCount))
                            .style(.callout, foreground: .secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading)
                .padding(.bottom, 8)
            }
        #endif
    }

    /// "≥" marks a total missing some prices.
    private var totalText: String {
        let value = "\(model.totalUSDValue.formattedAbbreviated()) US$"
        return model.partlyUnpricedCount > 0 ? "≥ \(value)" : value
    }

    #if os(macOS)
    @ViewBuilder
    private var content: some View {
        if !model.isLoaded {
            Color.clear
        } else if model.positions.isEmpty {
            EmptyStateView(.defiNoPositions)
                .accessibilityIdentifier("account-no-defi")
        } else {
            VStack(alignment: .leading, spacing: 16) {
                ForEach(model.kinds, id: \.self) { kind in
                    kind.section(model.positions(of: kind), blockchain: model.account.blockchain)
                }
            }
        }
    }
    #endif
}
