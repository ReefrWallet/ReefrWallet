//
//  AccountDefiView.swift
//  Reefr Wallet
//
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import SwiftUI

/// The DeFi tab: a one-column table with a collapsible section per plugin with stored records.
struct AccountDefiView: View {
    let model: AccountDefiModel

    @State private var collapsed: Set<DefiPluginKind> = []

    var body: some View {
        #if os(iOS)
        if isMainnet {
            AccountCountLabel(text: totalText)
                .opacity(model.isLoaded ? 1 : 0)
                .accessibilityIdentifier("account-defi-total")
        }

        if model.isLoaded, model.positions.isEmpty {
            AccountEmptyRow(title: .defiNoPositions)
                .accessibilityIdentifier("account-no-defi")
        } else {
            ForEach(model.pluginsWithPositions, id: \.kindId) { plugin in
                Section {
                    if !collapsed.contains(plugin.kindId) {
                        ForEach(model.positions(of: plugin.kindId)) { position in
                            plugin.row(position)
                        }
                    }
                } header: {
                    sectionHeader(plugin.kindId)
                }
            }
        }
        #else
        content
            .statusBar(edge: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    if isMainnet {
                        HStack(spacing: 4) {
                            Text(.commonTotalValueLabel)
                            Text(verbatim: totalText)
                                .accessibilityIdentifier("account-defi-total")
                        }
                        .opacity(model.isLoaded ? 1 : 0)
                        .style(.mediumHeader, foreground: .primary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading)
                .padding(.bottom, 8)
            }
        #endif
    }

    /// Testnet values aren't real dollars, so no total is shown.
    private var isMainnet: Bool {
        model.account.blockchain.isMainnet
    }

    private var totalText: String {
        Self.usd(model.total)
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
            Table(of: DefiPosition.self) {
                TableColumn(.accountDetailsDefi) { position in
                    model.plugins.first { $0.kindId == position.kind }?.row(position)
                }
            } rows: {
                ForEach(model.pluginsWithPositions, id: \.kindId) { plugin in
                    Section {
                        if !collapsed.contains(plugin.kindId) {
                            ForEach(model.positions(of: plugin.kindId)) { position in
                                TableRow(position)
                            }
                        }
                    } header: {
                        sectionHeader(plugin.kindId)
                    }
                }
            }
            .tableColumnHeaders(.hidden)
        }
    }
    #endif

    /// The plugin's title and total; toggles the section.
    private func sectionHeader(_ kind: DefiPluginKind) -> some View {
        let isExpanded = !collapsed.contains(kind)

        return Button {
            withAnimation(.snappy) {
                if isExpanded {
                    collapsed.insert(kind)
                } else {
                    collapsed.remove(kind)
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right")
                    .style(.small, foreground: .secondary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                Text(kind.title)
                Spacer()

                if isMainnet {
                    Text(verbatim: Self.usd(model.positions(of: kind).reduce(0) { $0 + $1.usdValue }))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityValue(Text(isExpanded ? .defiSectionExpanded : .defiSectionCollapsed))
        .accessibilityIdentifier("defi-section-\(kind.rawValue)")
    }

    private static func usd(_ value: Decimal) -> String {
        "\(value.formattedAbbreviated()) US$"
    }
}

private extension DefiPluginKind {
    var title: LocalizedStringResource {
        switch self {
        case .hyperliquid: .defiHyperliquidTitle
        case .uniswapV3: .defiUniswapV3Title
        }
    }
}

private extension DefiPlugin {
    var kindId: DefiPluginKind {
        Self.kind
    }

    /// The plugin's row behind `AnyView`: views over `[any DefiPlugin]` can't keep its type.
    @MainActor
    func row(_ position: DefiPosition) -> AnyView {
        AnyView(view(position))
    }
}
