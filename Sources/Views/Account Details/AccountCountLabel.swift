//
//  AccountCountLabel.swift
//  Reefr Wallet
//
//  Created by Andrey Yurkevich on 04.11.26.
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import SwiftUI

/// "N Balances" / "N Transactions" / "N Approvals" line shown above each tab's content.
struct AccountCountLabel: View {
    let text: String

    var body: some View {
        Text(verbatim: text)
            .style(.callout, foreground: .secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal)
            .padding(.vertical, 4)
            .listRowInsets(EdgeInsets())
            .listRowSeparator(.hidden)
    }
}

/// Placeholder row for an empty tab inside the tab's list.
struct AccountEmptyRow: View {
    let title: LocalizedStringResource

    var body: some View {
        EmptyStateView(title)
            .frame(minHeight: 320)
            .listRowInsets(EdgeInsets())
            .listRowSeparator(.hidden)
    }
}
