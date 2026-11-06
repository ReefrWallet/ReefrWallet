//
//  SolanaValidatorPicker.swift
//  Reefr Wallet
//
//  Created by Andrey Yurkevich on 06.11.26.
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import SwiftUI
import WalletKit

/// Picks the validator a stake goes to (ADR-054): a searchable list, best first.
/// Delinquent validators aren't offered.
struct SolanaValidatorPicker: View {
    let validators: [SolanaValidator]

    @Binding var selection: SolanaValidator?

    @State private var draft: SolanaValidator?
    @State private var searchText = ""

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        TransactionSheet(
            title: String(localized: .solanaStakingSelectValidator),
            confirmTitle: String(localized: .commonDone),
            isConfirmEnabled: draft != nil,
            onCancel: onCancel,
            onConfirm: onDone,
            accessibilityIds: .init(confirm: "validators-done-button", title: "validators-sheet-title")
        ) {
            ParameterSection(footer: String(localized: .solanaStakingNoteValidators)) {
                TextField(String(localized: .accountDetailsSearch), text: $searchText)
                    .accessibilityIdentifier("validators-search-field")

                if visible.isEmpty {
                    Text(.solanaStakingNoValidators)
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

private extension SolanaValidatorPicker {
    var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 8) {
                ForEach(visible) { validator in
                    row(validator)
                }
            }
        }
        #if os(macOS)
        .frame(height: 280)
        #else
        .frame(minHeight: 280)
        #endif
    }

    func row(_ validator: SolanaValidator) -> some View {
        let isSelected = draft?.id == validator.id

        return Button {
            draft = validator
        } label: {
            HStack(spacing: 10) {
                #if os(macOS)
                Image(systemName: isSelected ? "circle.inset.filled" : "circle")
                    .style(foreground: isSelected ? .accentColor : .secondary)
                #endif

                logo(validator)

                VStack(alignment: .leading, spacing: 2) {
                    Text(validator.name ?? validator.voteAddress.shortened(prefix: 6, suffix: 4))
                        .style(isPhone ? .large : .medium, foreground: .primary)

                    if let commission = validator.commission {
                        Text(.solanaStakingCommission(commission))
                            .style(.small, foreground: .secondary)
                    }
                }

                Spacer()

                if let apy = validator.apy {
                    Text(.solanaStakingApy("\(apy.formatted(.number.precision(.fractionLength(0...2))))%"))
                        .style(.medium, foreground: .primary)
                }

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
        .accessibilityIdentifier("validator-\(validator.id)")
    }

    func logo(_ validator: SolanaValidator) -> some View {
        let size: CGFloat = isPhone ? 28 : 24

        return AsyncImage(url: validator.imageURL) { image in
            image.resizable().scaledToFill()
        } placeholder: {
            Text(String((validator.name ?? "?").prefix(1)).uppercased())
                .style(.small, foreground: .secondary)
        }
        .frame(width: size, height: size)
        .background(Color.secondary.opacity(0.12))
        .clipShape(Circle())
    }
}

// MARK: - Logic

private extension SolanaValidatorPicker {
    func onCancel() {
        dismiss()
    }

    func onDone() {
        selection = draft
        dismiss()
    }

    var visible: [SolanaValidator] {
        let votable = validators.filter { !$0.isDelinquent }
        let query = searchText.trimmingCharacters(in: .whitespaces)

        guard !query.isEmpty else {
            return votable
        }

        return votable.filter {
            ($0.name ?? "").localizedCaseInsensitiveContains(query)
                || $0.voteAddress.localizedCaseInsensitiveContains(query)
        }
    }
}
