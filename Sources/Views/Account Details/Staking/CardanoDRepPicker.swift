//
//  CardanoDRepPicker.swift
//  Reefr Wallet
//
//  Created by Andrey Yurkevich on 08.11.26.
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import SwiftUI
import WalletKit

/// A DRep chosen in the picker, with the name its metadata gave if one was looked up.
struct CardanoDRepChoice: Equatable {
    let drep: CardanoDRep
    var name: String?

    var title: String {
        CardanoStakingModel.drepName(drep, name: name)
    }
}

/// Picks the DRep a stake key's vote goes to (ADR-059): Always Abstain, No Confidence, or a pasted
/// id that is checked on Blockfrost and shown by name. Optional when staking for the first time.
struct CardanoDRepPicker: View {
    let account: Account
    /// Whether the choice may be skipped for now.
    var isOptional = false

    @Binding var selection: CardanoDRepChoice?

    @State private var checked: CardanoDRepChoice?
    @State private var draft: CardanoDRepChoice?
    @State private var idText = ""
    @State private var isSkipping = false
    @State private var lookupFailure: String?

    @Environment(\.dismiss) private var dismiss

    private let service = DI.injectOrFail(CardanoStakingService.self)

    var body: some View {
        TransactionSheet(
            title: String(localized: .cardanoStakingSelectDrep),
            confirmTitle: String(localized: .commonDone),
            isConfirmEnabled: draft != nil || isSkipping,
            onCancel: onCancel,
            onConfirm: onDone,
            accessibilityIds: .init(confirm: "dreps-done-button", title: "dreps-sheet-title")
        ) {
            ParameterSection(footer: lookupFailure ?? String(localized: .cardanoStakingNoteDreps)) {
                TextField(String(localized: .cardanoStakingPasteDrep), text: $idText)
                    .accessibilityIdentifier("dreps-id-field")

                list
            }
        } fees: {
            EmptyView()
        }
        .onAppear {
            draft = selection
            isSkipping = isOptional && selection == nil
        }
        .task(id: idText) {
            await lookUp()
        }
    }
}

// MARK: - Rows

private extension CardanoDRepPicker {
    var list: some View {
        VStack(alignment: .leading, spacing: 8) {
            if isOptional {
                row(
                    title: String(localized: .cardanoStakingSkipForNow),
                    subtitle: String(localized: .cardanoStakingDrepSkipNote),
                    isSelected: isSkipping,
                    id: "skip"
                ) {
                    isSkipping = true
                    draft = nil
                }
            }

            ForEach(choices, id: \.drep) { choice in
                row(
                    title: choice.title,
                    subtitle: subtitle(choice),
                    isSelected: !isSkipping && draft?.drep == choice.drep,
                    id: "drep-\(choice.title)"
                ) {
                    isSkipping = false
                    draft = choice
                }
            }
        }
    }

    func row(
        title: String,
        subtitle: String?,
        isSelected: Bool,
        id: String,
        select: @escaping () -> Void
    ) -> some View {
        Button(action: select) {
            HStack(spacing: 10) {
                #if os(macOS)
                Image(systemName: isSelected ? "circle.inset.filled" : "circle")
                    .style(foreground: isSelected ? .accentColor : .secondary)
                #endif

                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: title)
                        .style(isIOS ? .large : .medium, foreground: .primary)

                    if let subtitle {
                        Text(verbatim: subtitle)
                            .style(.small, foreground: .secondary)
                    }
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
        .accessibilityIdentifier(id)
    }

    func subtitle(_ choice: CardanoDRepChoice) -> String? {
        switch choice.drep {
        case .abstain: String(localized: .cardanoStakingDrepAbstainNote)
        case .noConfidence: String(localized: .cardanoStakingDrepNoConfidenceNote)
        case let .id(id): id.shortened(prefix: 10, suffix: 4)
        }
    }
}

// MARK: - Logic

private extension CardanoDRepPicker {
    /// The predefined DReps, then a pasted one once it checked out.
    var choices: [CardanoDRepChoice] {
        [CardanoDRepChoice(drep: .abstain), CardanoDRepChoice(drep: .noConfidence)] + [checked].compactMap { $0 }
    }

    func onCancel() {
        dismiss()
    }

    func onDone() {
        selection = isSkipping ? nil : draft
        dismiss()
    }

    /// A pasted id is checked on Blockfrost: registered and not retired, else it isn't offered.
    func lookUp() async {
        checked = nil
        lookupFailure = nil

        let id = idText.trimmingCharacters(in: .whitespaces)

        guard !id.isEmpty else {
            return
        }

        guard id.hasPrefix("drep") else {
            lookupFailure = String(localized: .cardanoStakingDrepInvalid)
            return
        }

        do {
            if let info = try await service.drep(id, account: account) {
                let choice = CardanoDRepChoice(drep: .id(info.drepId), name: info.name)
                checked = choice
                draft = choice
                isSkipping = false
            } else {
                lookupFailure = String(localized: .cardanoStakingErrorDrepUnavailable)
            }
        } catch {
            lookupFailure = String(localized: .cardanoStakingDrepLookupFailed)
        }
    }
}
