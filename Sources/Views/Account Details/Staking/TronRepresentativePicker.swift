//
//  TronRepresentativePicker.swift
//  Reefr Wallet
//
//  Created by Andrey Yurkevich on 05.11.26.
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import SwiftUI
import WalletKit

/// Picks the representatives a vote goes to (ADR-052): a searchable list with
/// checkboxes, capped at ``TronStakingService/maxRepresentatives``.
struct TronRepresentativePicker: View {
    let representatives: [TronRepresentative]

    @Binding var selection: [TronRepresentative]

    @State private var draft: [TronRepresentative] = []
    @State private var searchText = ""

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        TransactionSheet(
            title: String(localized: .tronStakingSelectRepresentatives),
            confirmTitle: String(localized: .commonDone),
            isConfirmEnabled: true,
            onCancel: onCancel,
            onConfirm: onDone,
            accessibilityIds: .init(confirm: "representatives-done-button", title: "representatives-sheet-title")
        ) {
            ParameterSection(
                footer: String(localized: .tronStakingNoteSelect(TronStakingService.maxRepresentatives))
            ) {
                TextField(String(localized: .accountDetailsSearch), text: $searchText)
                    .accessibilityIdentifier("representatives-search-field")

                if visible.isEmpty {
                    Text(.tronStakingNoRepresentatives)
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
    }
}

// MARK: - Rows

private extension TronRepresentativePicker {
    var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 8) {
                ForEach(visible) { representative in
                    row(representative)
                }
            }
        }
        #if os(macOS)
        .frame(height: 280)
        #else
        .frame(minHeight: 280)
        #endif
    }

    func row(_ representative: TronRepresentative) -> some View {
        let isSelected = draft.contains { $0.id == representative.id }
        let isDisabled = !isSelected && draft.count >= TronStakingService.maxRepresentatives

        return Toggle(isOn: Binding(get: { isSelected }, set: { toggle(representative, isOn: $0) })) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(representative.name ?? representative.address.string.shortened(prefix: 6, suffix: 4))
                        .style(isPhone ? .large : .medium, foreground: .primary)

                    Text(representative.address.string)
                        .style(.smallMono, foreground: .secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer()

                if let apr = representative.apr {
                    Text(
                        .tronStakingApr(
                            (apr / 100.0).formatted(.percent.precision(.fractionLength(0...2)))
                        )
                    )
                    .style(.medium, foreground: .secondary)
                }
            }
        }
        .disabled(isDisabled)
        .accessibilityIdentifier("representative-\(representative.id)")
    }
}

// MARK: - Logic

private extension TronRepresentativePicker {
    func onCancel() {
        dismiss()
    }

    func onDone() {
        selection = draft
        dismiss()
    }

    /// The representatives matching the search, with the ones already voted for kept
    /// even if the list doesn't know them (they are then listed by address).
    var visible: [TronRepresentative] {
        let known = Set(representatives.map(\.id))
        let all = representatives + draft.filter { !known.contains($0.id) }
        let query = searchText.trimmingCharacters(in: .whitespaces)

        guard !query.isEmpty else {
            return all
        }

        return all.filter {
            ($0.name ?? "").localizedCaseInsensitiveContains(query)
                || $0.address.string.localizedCaseInsensitiveContains(query)
        }
    }

    func toggle(_ representative: TronRepresentative, isOn: Bool) {
        if isOn {
            guard draft.count < TronStakingService.maxRepresentatives else {
                return
            }

            draft.append(representative)
        } else {
            draft.removeAll { $0.id == representative.id }
        }
    }
}
