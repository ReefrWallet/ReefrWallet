//
//  AddKeyStoreView.swift
//  Reefr Wallet
//
//  Created by Andrey Yurkevich on 31.12.25.
//  Copyright © 2025 Reefr Wallet. All rights reserved.
//

import SwiftData
import SwiftUI
import WalletKit

// MARK: - AddKeyStoreView

struct AddKeyStoreView: View {
    enum FocusTarget: Hashable {
        case next
    }

    enum ViewState: Equatable {
        case newKey
        case chooseAction
        case restore
    }

    enum Options {
        static let connectTrezor = UUID()
        static let generateNewKey = UUID()
        static let restoreFromBackup = UUID()
    }

    @State private var error: Swift.Error?
    @State private var isAlertPresented = false
    @State private var isBackButtonDisabled = false
    @State private var isNextButtonDisabled = true
    @State private var seedPhrase = ""
    @State private var selectedOption: UUID?
    @State private var viewState: ViewState = .chooseAction

    @FocusState private var focus: FocusTarget?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.sidebarSelection) private var sidebarSelection: Binding<PersistentIdentifier?>

    private let databaseService = DI.injectOrFail(DatabaseService.self)
    private let keyStoreService = DI.injectOrFail(KeyStoreService.self)

    var body: some View {
        VStack(alignment: .leading) {
            switch viewState {
            case .newKey:
                generatedKeyView
            case .chooseAction:
                chooseKeyTypeView
            case .restore:
                editableKeyView
            }

            buttonsView
        }
        .padding()
        .onChange(of: selectedOption) { _, newValue in
            switch newValue {
            case Options.connectTrezor:
                isNextButtonDisabled = false
            case Options.generateNewKey:
                isNextButtonDisabled = false
            case Options.restoreFromBackup:
                isNextButtonDisabled = false
            default:
                break
            }
        }
        .alert("Error", isPresented: $isAlertPresented) {
            Button("OK") {
                isAlertPresented = false

                if case .alreadyExists = error as? ReefrError {
                    return
                }

                dismiss()
            }
        } message: {
            Text(alertMessage(error))
        }
    }
}

// MARK: - Subviews

private extension AddKeyStoreView {
    var buttonsView: some View {
        HStack {
            Spacer()

            Button {
                onBackButtonPressed()
            } label: {
                Text(backButtonLabel)
            }
            .focusable(viewState == .chooseAction)
            .focusEffectDisabled()
            .disabled(isBackButtonDisabled)

            Button {
                onNextButtonPressed()
            } label: {
                Text(nextButtonLabel)
            }
            .focused($focus, equals: .next)
            .keyboardShortcut(.defaultAction)
            .disabled(isNextButtonDisabled)
        }
    }

    var chooseKeyTypeView: some View {
        VStack {
            Picker("", selection: $selectedOption) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("New Hardware Key")
                        .style(.medium, foreground: .primary)
                    Text("Connect Trezor hardware key and\nuse it for address derivation and signing")
                        .style(.small, foreground: .secondary)
                }
                .tag(Options.connectTrezor)

                VStack(alignment: .leading, spacing: 4) {
                    Text("New BIP-39 Mnemonic")
                        .style(.medium, foreground: .primary)
                    Text("Generate 12, 18 or 24 word seed phrase wallet\nstored locally on this computer")
                        .style(.small, foreground: .secondary)
                }
                .tag(Options.generateNewKey)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Restore From Backup")
                        .style(.medium, foreground: .primary)
                    Text("Restore local seed phrase wallet\nfrom a 12, 18 or 24 word backup")
                        .style(.small, foreground: .secondary)
                }
                .tag(Options.restoreFromBackup)
            }
            #if os(macOS)
            .pickerStyle(.radioGroup)
            #endif
        }
    }

    var editableKeyView: some View {
        WordTokenizerView(
            phrase: $seedPhrase,
            columns: 4
        )
            .onChange(of: seedPhrase, initial: true) { _, newValue in
                validateSeedPhrase(newValue)
            }
    }

    var generatedKeyView: some View {
        WordTokenizerView(phrase: $seedPhrase, columns: 4, readOnly: true)
            .onChange(of: seedPhrase, initial: true) { _, newValue in
                validateSeedPhrase(newValue)
            }
    }
}

// MARK: - Logic

extension AddKeyStoreView {
    var backButtonLabel: String {
        switch viewState {
        case .chooseAction:
            "Cancel"
        case .newKey, .restore:
            "Back"
        }
    }

    var nextButtonLabel: String {
        switch viewState {
        case .newKey:
            "Done"
        case .chooseAction, .restore:
            "Next"
        }
    }

    func alertMessage(_ error: Swift.Error?) -> String {
        guard let error else {
            return "Unknown Error."
        }

        switch error {
        case ReefrError.alreadyExists:
            return "Key store already exists."
        default:
            return error.localizedDescription
        }
    }

    func onBackButtonPressed() {
        switch viewState {
        case .chooseAction:
            dismiss()
        case .newKey, .restore:
            viewState = .chooseAction
        }
    }

    func onNextButtonPressed() {
        switch viewState {
        case .chooseAction:
            guard let selectedOption else {
                preconditionFailure("No option selected")
            }

            Task {
                switch selectedOption {
                case Options.connectTrezor:
                    do {
                        try await keyStoreService.connectTrezor()
                        dismiss()
                    } catch {
                        self.error = error
                        isAlertPresented = true
                    }

                case Options.generateNewKey:
                    seedPhrase = keyStoreService.generateSeedPhrase()
                    viewState = .newKey
                case Options.restoreFromBackup:
                    seedPhrase = ""
                    viewState = .restore
                default:
                    preconditionFailure("Unknown option selected: \(selectedOption)")
                }
            }

        case .newKey, .restore:
            Task {
                do {
                    let mnemonic = try Mnemonic.fromPhrase(seedPhrase)
                    try await keyStoreService.addLocalKey(mnemonic)
                    dismiss()
                } catch {
                    self.error = error
                    isAlertPresented = true
                }
            }
        }
    }

    @MainActor
    func validateSeedPhrase(_ seedPhrase: String) {
        do {
            _ = try Mnemonic.fromPhrase(seedPhrase)
            isNextButtonDisabled = false
        } catch {
            isNextButtonDisabled = true
        }
    }
}

// MARK: - Preview

#Preview {
    AddKeyStoreView()
}
