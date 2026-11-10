//
//  SuiValidatorPicker.swift
//  Reefr Wallet
//
//  Created by Andrey Yurkevich on 08.11.26.
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import SwiftUI
import WalletKit

/// Picks the validator a stake goes to (ADR-060): a searchable list by name, with each one's
/// commission. There is no APY: Sui has no source for it.
struct SuiValidatorPicker: View {
    let validators: [SuiValidator]

    @Binding var selection: SuiValidator?

    @State private var draft: SuiValidator?
    @State private var searchText = ""

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        TransactionSheet(
            title: String(localized: .suiStakingSelectValidator),
            confirmTitle: String(localized: .commonDone),
            isConfirmEnabled: draft != nil,
            onCancel: onCancel,
            onConfirm: onDone,
            accessibilityIds: .init(confirm: "validators-done-button", title: "validators-sheet-title")
        ) {
            ParameterSection(footer: String(localized: .suiStakingNoteValidators)) {
                TextField(String(localized: .accountDetailsSearch), text: $searchText)
                    .accessibilityIdentifier("validators-search-field")

                if visible.isEmpty {
                    Text(.suiStakingNoValidators)
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

private extension SuiValidatorPicker {
    var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 8) {
                ForEach(visible, id: \.address) { validator in
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

    func row(_ validator: SuiValidator) -> some View {
        let isSelected = draft?.address == validator.address

        return Button {
            draft = validator
        } label: {
            HStack(spacing: 10) {
                #if os(macOS)
                Image(systemName: isSelected ? "circle.inset.filled" : "circle")
                    .style(foreground: isSelected ? .accentColor : .secondary)
                #endif

                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: validator.name)
                        .style(isPhone ? .large : .medium, foreground: .primary)

                    Text(.suiStakingCommission(Self.commissionText(validator)))
                        .style(.small, foreground: .secondary)
                }

                Spacer()

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
        .accessibilityIdentifier("validator-\(validator.address)")
    }
}

// MARK: - Logic

extension SuiValidatorPicker {
    /// `5%`: the commission is reported in basis points.
    static func commissionText(_ validator: SuiValidator) -> String {
        (Decimal(validator.commissionBasisPoints) / 10_000).formatted(.percent.precision(.fractionLength(0...2)))
    }
}

private extension SuiValidatorPicker {
    func onCancel() {
        dismiss()
    }

    func onDone() {
        selection = draft
        dismiss()
    }

    var visible: [SuiValidator] {
        let query = searchText.trimmingCharacters(in: .whitespaces)

        guard !query.isEmpty else {
            return validators
        }

        return validators.filter {
            $0.name.localizedCaseInsensitiveContains(query) || $0.address.localizedCaseInsensitiveContains(query)
        }
    }
}
