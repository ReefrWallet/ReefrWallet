//
//  AddReceiveAddressSheet.swift
//  Reefr Wallet
//
//  Created by Andrey Yurkevich on 07.11.26.
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import SwiftData
import SwiftUI

/// Derives the next receive address, or one at a custom index. No key or network is needed.
struct AddReceiveAddressSheet: View {
    let account: Account

    @State private var draft = ReceiveAddressDraft(rows: [])
    @State private var errorMessage: String?

    @Query private var models: [ReceiveAddressModel]

    @Environment(\.dismiss) private var dismiss

    init(_ account: Account) {
        guard let accountId = account.id else {
            preconditionFailure()
        }

        self.account = account

        _models = Query(filter: #Predicate<ReceiveAddressModel> { $0.account.id == accountId })
    }

    var body: some View {
        // The draft's rows follow the query, so a refresh behind the sheet is reflected.
        let current = ReceiveAddressDraft(
            rows: models.map(ReceiveAddress.init(model:)),
            isCustom: draft.isCustom,
            text: draft.text
        )

        Group {
            if isPhone {
                form(current)
                    .phoneSheet(
                        .addressesSheetTitlePhone,
                        onCancel: { dismiss() },
                        confirmTitle: .addressesAdd,
                        confirmId: "add-address-submit-button",
                        isConfirmEnabled: current.isAddEnabled,
                        onConfirm: { submit(current) }
                    )
            } else {
                VStack(alignment: .leading) {
                    Text(.addressesSheetTitleMac)
                        .style(.largeHeader, foreground: .primary)
                        .padding(.bottom)

                    form(current)

                    HStack {
                        Spacer()

                        Button(.commonCancel) { dismiss() }
                            .keyboardShortcut(.cancelAction)

                        Button(.addressesAddAddress) { submit(current) }
                            .keyboardShortcut(.defaultAction)
                            .disabled(!current.isAddEnabled)
                            .accessibilityIdentifier("add-address-submit-button")
                    }
                }
                .padding()
                .frame(minWidth: 400)
            }
        }
        .alert(
            .addressesSheetTitlePhone,
            isPresented: Binding(get: { errorMessage != nil }, set: { _ in errorMessage = nil })
        ) {
            Button(.commonOk) {}
        } message: {
            Text(verbatim: errorMessage ?? "")
        }
    }

    private func form(_ current: ReceiveAddressDraft) -> some View {
        Form {
            Section {
                Toggle(.addressesCustomIndex, isOn: $draft.isCustom)
                    .accessibilityIdentifier("add-address-custom-toggle")

                TextField(
                    String(localized: .addressesAddressIndex),
                    text: current.isCustom ? $draft.text : .constant(current.index.map(String.init) ?? "")
                )
                .disabled(!current.isCustom)
                .accessibilityIdentifier("add-address-index-field")
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(noteText(current))

                    if current.isPastGap {
                        Text(.addressesGapWarning)
                            .foregroundStyle(.orange)
                    }
                }
            }
        }
    }

    private func noteText(_ current: ReceiveAddressDraft) -> LocalizedStringResource {
        switch current.note {
        case .allListed: .addressesAllListed
        case .invalidIndex: .addressesInvalidIndex
        case let .lowestFree(index): .addressesDerivesLowestFree(path(index))
        case let .next(index, newest): .addressesDerivesNext(path(index), Int(newest))
        case let .custom(index): .addressesDerives(path(index))
        }
    }

    /// Watch-only accounts have no hardened origin, so they show the path relative to it.
    private func path(_ index: UInt32) -> String {
        guard let origin = account.derivationPath?.string else {
            return "0/\(index)"
        }

        return "\(origin)/0/\(index)"
    }

    private func submit(_ current: ReceiveAddressDraft) {
        guard let index = current.index else {
            return
        }

        Task {
            do {
                let service = ReceiveAddressService(databaseService: DI.injectOrFail(DatabaseService.self))
                try await service.add(index: index, to: account)
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
