//
//  CardanoPoolPicker.swift
//  Reefr Wallet
//
//  Created by Andrey Yurkevich on 08.11.26.
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import SwiftUI
import WalletKit

/// Picks the pool a stake delegates to (ADR-059): a searchable list from Blockfrost, best first.
/// A pasted pool id that isn't listed is looked up and offered when it can be delegated to.
struct CardanoPoolPicker: View {
    let account: Account

    @Binding var selection: CardanoPool?

    @State private var draft: CardanoPool?
    @State private var failure: String?
    @State private var isLoading = true
    @State private var lookedUp: CardanoPool?
    @State private var pools: [CardanoPool] = []
    @State private var searchText = ""

    @Environment(\.dismiss) private var dismiss

    private let service = DI.injectOrFail(CardanoStakingService.self)

    var body: some View {
        let saturationThreshold = 1.0.formatted(.percent)

        TransactionSheet(
            title: String(localized: .cardanoStakingSelectPool),
            confirmTitle: String(localized: .commonDone),
            isConfirmEnabled: draft != nil,
            onCancel: onCancel,
            onConfirm: onDone,
            accessibilityIds: .init(confirm: "pools-done-button", title: "pools-sheet-title")
        ) {
            ParameterSection(footer: failure ?? String(localized: .cardanoStakingNotePools(saturationThreshold))) {
                TextField(String(localized: .accountDetailsSearch), text: $searchText)
                    .accessibilityIdentifier("pools-search-field")

                if isLoading {
                    if !isPhone {
                        ProgressView()
                            .frame(maxWidth: .infinity, minHeight: 120)
                    }
                } else if visible.isEmpty {
                    Text(.cardanoStakingNoPools)
                        .style(.medium, foreground: .secondary)
                } else {
                    list
                }
            }
        } fees: {
            EmptyView()
        }
        .onAppear {
            draft = selection
        }
        .task {
            await load()
        }
        .task(id: searchText) {
            await lookUp()
        }
    }
}

// MARK: - Rows

private extension CardanoPoolPicker {
    var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 8) {
                ForEach(visible) { pool in
                    row(pool)
                }
            }
        }
        #if os(macOS)
        .frame(height: 280)
        #else
        .frame(minHeight: 280)
        #endif
    }

    func row(_ pool: CardanoPool) -> some View {
        let isSelected = draft?.poolId == pool.poolId

        return Button {
            draft = pool
        } label: {
            HStack(spacing: 10) {
                #if os(macOS)
                Image(systemName: isSelected ? "circle.inset.filled" : "circle")
                    .style(foreground: isSelected ? .accentColor : .secondary)
                #endif

                logo(pool)

                VStack(alignment: .leading, spacing: 2) {
                    Text(CardanoStakingModel.poolName(ticker: pool.ticker, name: pool.name, poolId: pool.poolId))
                        .style(isPhone ? .large : .medium, foreground: .primary)

                    Text(.cardanoStakingPoolTerms(
                        CardanoStakingFormat.percent(pool.marginCost),
                        CardanoStakingFormat.ada(pool.fixedCost)
                    ))
                    .style(.small, foreground: .secondary)
                }

                Spacer()

                Text(.cardanoStakingSaturated(CardanoStakingFormat.percent(pool.saturation)))
                    .style(.medium, foreground: pool.saturation > 1 ? .caution : .primary)

                #if os(iOS)
                if isSelected {
                    Image(systemName: "checkmark")
                        .style(foreground: .accentColor)
                }
                #endif
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("pool-\(pool.poolId)")
    }

    func logo(_ pool: CardanoPool) -> some View {
        let size: CGFloat = isPhone ? 28 : 24

        return Text(String((pool.ticker ?? pool.name ?? "?").prefix(1)).uppercased())
            .style(.small, foreground: .secondary)
            .frame(width: size, height: size)
            .background(Color.secondary.opacity(0.12))
            .clipShape(Circle())
    }
}

// MARK: - Logic

private extension CardanoPoolPicker {
    func onCancel() {
        dismiss()
    }

    func onDone() {
        selection = draft
        dismiss()
    }

    var visible: [CardanoPool] {
        let query = searchText.trimmingCharacters(in: .whitespaces)

        guard !query.isEmpty else {
            return pools
        }

        var matches = pools.filter {
            ($0.name ?? "").localizedCaseInsensitiveContains(query)
                || ($0.ticker ?? "").localizedCaseInsensitiveContains(query)
                || $0.poolId.localizedCaseInsensitiveContains(query)
        }

        if let lookedUp, !matches.contains(where: { $0.poolId == lookedUp.poolId }) {
            matches.insert(lookedUp, at: 0)
        }

        return matches
    }

    /// The list loads when the picker opens; a failure keeps the field usable for a pasted id.
    func load() async {
        do {
            pools = try await service.pools(for: account)
            failure = nil
        } catch {
            failure = String(localized: .cardanoStakingPoolsFailed)
        }

        isLoading = false
    }

    /// A pasted `pool1…` id missing from the list is asked for directly.
    func lookUp() async {
        lookedUp = nil

        let query = searchText.trimmingCharacters(in: .whitespaces)

        guard query.hasPrefix("pool1"), !pools.contains(where: { $0.poolId == query }) else {
            return
        }

        lookedUp = try? await service.pool(query, account: account)
    }
}
