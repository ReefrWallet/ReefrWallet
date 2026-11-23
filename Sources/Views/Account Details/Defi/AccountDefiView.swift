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
            Table(of: DefiTableEntry.self) {
                TableColumn(.accountDetailsDefi) { entry in
                    switch entry {
                    case let .header(kind):
                        sectionHeader(kind)
                    case let .position(position):
                        model.plugins.first { $0.kindId == position.kind }?.row(position)
                    }
                }
            } rows: {
                ForEach(model.pluginsWithPositions, id: \.kindId) { plugin in
                    DisclosureTableRow(DefiTableEntry.header(plugin.kindId), isExpanded: isExpanded(plugin.kindId)) {
                        Optional<TableRow<DefiTableEntry>>.none
                    }

                    if !collapsed.contains(plugin.kindId) {
                        ForEach(model.positions(of: plugin.kindId)) { position in
                            TableRow(DefiTableEntry.position(position))
                        }
                    }
                }
            }
            .tableColumnHeaders(.hidden)
        }
    }
    #endif

    private func isExpanded(_ kind: DefiPluginKind) -> Binding<Bool> {
        Binding {
            !collapsed.contains(kind)
        } set: { isExpanded in
            withAnimation {
                if isExpanded {
                    collapsed.remove(kind)
                } else {
                    collapsed.insert(kind)
                }
            }
        }
    }

    /// The plugin's title, styled like the Tokens tab's hidden balances; toggles the section.
    private func sectionHeader(_ kind: DefiPluginKind) -> some View {
        let isExpanded = isExpanded(kind)

        #if os(iOS)
        return Button {
            isExpanded.wrappedValue.toggle()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right")
                    .rotationEffect(.degrees(isExpanded.wrappedValue ? 90 : 0))
                Text(kind.title)
                Spacer()
            }
            .style(.smallHeader, foreground: .secondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityValue(Text(isExpanded.wrappedValue ? .defiSectionExpanded : .defiSectionCollapsed))
        .accessibilityIdentifier("defi-section-\(kind.rawValue)")
        #else
        return Text(kind.title)
            .style(.smallHeader, foreground: .secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture {
                isExpanded.wrappedValue.toggle()
            }
            .accessibilityAddTraits(.isButton)
            .accessibilityValue(Text(isExpanded.wrappedValue ? .defiSectionExpanded : .defiSectionCollapsed))
            .accessibilityIdentifier("defi-section-\(kind.rawValue)")
        #endif
    }

    private static func usd(_ value: Decimal) -> String {
        "\(value.formattedAbbreviated()) US$"
    }
}

#if os(macOS)
/// A DeFi table row: a plugin's disclosure header or one of its records.
private enum DefiTableEntry: Identifiable {
    case header(DefiPluginKind)
    case position(DefiPosition)

    var id: String {
        switch self {
        case let .header(kind): "header:\(kind.rawValue)"
        case let .position(position): "position:\(position.id)"
        }
    }
}
#endif

private extension DefiPluginKind {
    var title: LocalizedStringResource {
        switch self {
        case .hyperliquid: .defiHyperliquidTitle
        case .revertLend: .defiRevertLendTitle
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
