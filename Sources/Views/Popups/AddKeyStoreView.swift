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
    enum ViewState: Equatable {
        case addLocalKey
        case chooseAction
        case restore
    }

    enum Options {
        static let connectTrezor = UUID().uuidString
        static let generateNewKey = UUID().uuidString
        static let restoreFromBackup = UUID().uuidString
    }

    @State private var error: Swift.Error?
    @State private var isAlertPresented = false
    @State private var isBackButtonDisabled = false
    @State private var isNextButtonDisabled = true
    @State private var seedPhrase = ""
    @State private var selectedOption: String?
    @State private var viewState: ViewState = .chooseAction

    @Environment(\.dismiss) private var dismiss
    @Environment(\.sidebarSelection) private var sidebarSelection: Binding<PersistentIdentifier?>

    private let databaseService = DI.injectOrFail(DatabaseService.self)
    private let keyStoreService = DI.injectOrFail(KeyStoreService.self)

    var body: some View {
        VStack(alignment: .leading) {
            switch viewState {
            case .addLocalKey:
                newLocalKeyView
            case .chooseAction:
                chooseKeyTypeView
            case .restore:
                restoreKeyView
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
            .disabled(isBackButtonDisabled)

            Button {
                onNextButtonPressed()
            } label: {
                Text(nextButtonLabel)
            }
            .disabled(isNextButtonDisabled)
        }
    }

    var chooseKeyTypeView: some View {
        VStack {
            SelectionGroupView(options: hardwareKeyOptions, selectedOption: $selectedOption)
                .padding(.bottom)

            SelectionGroupView(options: localKeyOptions, selectedOption: $selectedOption)
                .padding(.bottom)
        }
    }

    var newLocalKeyView: some View {
        TextEditor(text: $seedPhrase)
            .frame(minHeight: 200)
            .onChange(of: seedPhrase, initial: true) { _, newValue in
                validateSeedPhrase(newValue)
            }
    }

    var restoreKeyView: some View {
        TextEditor(text: $seedPhrase)
            .frame(minHeight: 200)
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
        case .addLocalKey, .restore:
            "Back"
        }
    }

    var hardwareKeyOptions: [SelectionOption] {
        [
            SelectionOption(
                id: Options.connectTrezor,
                title: "Add Trezor",
                image: Image(systemName: "key.fill")
            )
        ]
    }

    var localKeyOptions: [SelectionOption] {
        [
            SelectionOption(
                id: Options.generateNewKey,
                title: "Generate New Key",
                image: Image(systemName: "key.fill")
            ),
            SelectionOption(
                id: Options.restoreFromBackup,
                title: "Restore From Backup",
                image: Image(systemName: "arrow.clockwise.circle.fill")
            )
        ]
    }

    var nextButtonLabel: String {
        switch viewState {
        case .addLocalKey:
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
        case Error.alreadyExists:
            return "Key store already exists."
        default:
            return error.localizedDescription
        }
    }

    func onBackButtonPressed() {
        switch viewState {
        case .chooseAction:
            dismiss()
        case .addLocalKey, .restore:
            viewState = .chooseAction
        }
    }

    func onNextButtonPressed() {
        switch viewState {
        case .chooseAction:
            let allOptions = hardwareKeyOptions + localKeyOptions

            guard let selectedOption,
                  let option = allOptions.first(where: { $0.id == selectedOption }) else {
                preconditionFailure("No option selected")
            }

            Task {
                switch option.id {
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
                    viewState = .restore
                case Options.restoreFromBackup:
                    seedPhrase = ""
                    viewState = .restore
                default:
                    preconditionFailure("Unknown option selected: \"\(option.title)\" (\(option.id))")
                }
            }
        case .addLocalKey, .restore:
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
