//
//  AddTokenSheet.swift
//  Reefr Wallet
//
//  Created by Andrey Yurkevich on 14.11.26.
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import SwiftUI

/// Adds a token by contract address for the account's whole blockchain.
struct AddTokenSheet: View {
    let account: Account

    @State private var address = ""
    @State private var errorMessage: String?
    @State private var isAdding = false

    @Environment(\.dismiss) private var dismiss

    init(_ account: Account) {
        self.account = account
    }

    var body: some View {
        Group {
            if isIOS {
                phoneBody
            } else {
                macBody
            }
        }
        .alert(
            .tokensAddToken,
            isPresented: Binding(get: { errorMessage != nil }, set: { _ in errorMessage = nil })
        ) {
            Button(.commonOk) {}
        } message: {
            Text(verbatim: errorMessage ?? "")
        }
    }

    private var phoneBody: some View {
        Form {
            Section {
                addressField
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
            } footer: {
                Text(.tokensAddTokenFootnote)
            }
        }
        .phoneSheet(
            .tokensAddToken,
            onCancel: { dismiss() },
            confirmTitle: .tokensAdd,
            confirmId: "add-token-submit-button",
            isConfirmEnabled: isAddEnabled,
            onConfirm: submit
        )
    }

    private var macBody: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(.tokensAddToken)
                .style(.largeHeader)

            addressField
                .textFieldStyle(.roundedBorder)

            Text(.tokensAddTokenFootnote)
                .style(.small, foreground: .secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                if isAdding {
                    ProgressView()
                        .controlSize(.small)
                }

                Spacer()

                Button(.commonCancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)

                Button(.tokensAddToken, action: submit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!isAddEnabled)
                    .accessibilityIdentifier("add-token-submit-button")
            }
            .padding(.top, 8)
        }
        .padding()
        .frame(width: 440)
    }

    private var addressField: some View {
        TextField("", text: $address, prompt: Text(.tokensContractAddress).foregroundStyle(.secondary))
            .autocorrectionDisabled()
            .disabled(isAdding)
            .onSubmit(submit)
            .accessibilityIdentifier("add-token-address-field")
    }

    private var isAddEnabled: Bool {
        !isAdding && (try? CustomTokenService.normalizedAddress(address, blockchain: account.blockchain)) != nil
    }

    private func submit() {
        guard isAddEnabled else {
            return
        }

        isAdding = true

        Task {
            defer { isAdding = false }

            do {
                let service = CustomTokenService(databaseService: DI.injectOrFail(DatabaseService.self))
                try await service.addToken(contractAddress: address, account: account)
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
