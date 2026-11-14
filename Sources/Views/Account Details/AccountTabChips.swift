//
//  AccountTabChips.swift
//  Reefr Wallet
//
//  Created by Andrey Yurkevich on 03.11.26.
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import SwiftUI

enum AccountTab: String, CaseIterable, Identifiable {
    case addresses
    case approvals
    case balances
    case staking
    case tokens
    case transactions

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .addresses: "list.number"
        case .approvals: "checkmark.shield"
        case .balances: "chart.pie"
        case .staking: "lock"
        case .tokens: "circle.hexagongrid"
        case .transactions: "arrow.left.arrow.right"
        }
    }

    var title: LocalizedStringResource {
        switch self {
        case .addresses: .accountDetailsAddresses
        case .approvals: .accountDetailsApprovals
        case .balances: .accountDetailsBalances
        case .staking: .accountDetailsStaking
        case .tokens: .accountDetailsTokens
        case .transactions: .accountDetailsTransactions
        }
    }
}

#if os(iOS)
/// Mail-style category chips: the selected one is a dark capsule with its title filling the free width,
/// the rest are icon-only.
struct AccountTabChips: View {
    let tabs: [AccountTab]

    @Binding var selection: AccountTab

    @State private var iconWidths: [AccountTab: CGFloat] = [:]

    var body: some View {
        GeometryReader { proxy in
            let available = proxy.size.width - 2 * Self.horizontalInset
            let spacing = CGFloat(tabs.count - 1) * Self.spacing

            let selectedWidth = max(
                Self.compactWidth,
                available - spacing - CGFloat(tabs.count - 1) * Self.compactWidth
            )

            HStack(spacing: Self.spacing) {
                ForEach(tabs) { tab in
                    chip(tab, width: tab == selection ? selectedWidth : Self.compactWidth)
                }
            }
            .padding(.horizontal, Self.horizontalInset)
            .animation(.snappy, value: selection)
        }
        .frame(height: Self.height)
        .padding(.vertical, 8)
    }

    private static let compactWidth: CGFloat = 56
    private static let height: CGFloat = 44
    private static let horizontalInset: CGFloat = 16
    private static let spacing: CGFloat = 8

    private func chip(_ tab: AccountTab, width: CGFloat) -> some View {
        let isSelected = tab == selection

        return Button {
            selection = tab
        } label: {
            HStack(spacing: 6) {
                Image(systemName: tab.systemImage)
                    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { iconWidths[tab] = $0 }

                Text(tab.title)
                    .lineLimit(1)
                    .opacity(isSelected ? 1 : 0)
            }
            .style(.headline, foreground: isSelected ? Color(.systemBackground) : .primary)
            .fixedSize()
            .padding(.leading, isSelected ? 16 : (Self.compactWidth - (iconWidths[tab] ?? 0)) / 2)
            .frame(width: width, height: Self.height, alignment: .leading)
            .background {
                Capsule()
                    .fill(isSelected ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary.opacity(0.15)))
            }
            .clipShape(Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(tab.title))
        .accessibilityIdentifier("account-tab-\(tab.rawValue)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
#endif
