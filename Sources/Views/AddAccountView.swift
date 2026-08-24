//
//  AddAccountView.swift
//  Reefr Wallet
//
//  Created by Andrey Yurkevich on 31.12.25.
//  Copyright © 2025 Reefr Wallet. All rights reserved.
//

import SwiftData
import SwiftUI
import WalletKit

// MARK: - AddAccountView

struct AddAccountView: View {
    let keyStore: KeyStore

    @State private var address = ""
    @State private var blockchains: [WKBlockchain]
    @State private var error: Swift.Error?
    @State private var isAlertPresented = false
    @State private var networks: [WKBlockchain]

    @State private var selectedBlockchain: WKBlockchain
    @State private var selectedKeyScheme: Curve?
    @State private var selectedNetwork: WKBlockchain?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.sidebarSelection) private var sidebarSelection: Binding<PersistentIdentifier?>

    init(keyStore: KeyStore) {
        self.keyStore = keyStore

        let blockchains = WKBlockchain.allMainnets
        let selectedBlockchain = blockchains.first!
        let networks = selectedBlockchain.allNetworks

        self.blockchains = blockchains
        self.networks = networks
        self.selectedNetwork = networks.first
        self.selectedBlockchain = selectedBlockchain
    }
}

// MARK: - View

extension AddAccountView {
    var body: some View {
        VStack {
            Text("Add Blockchain AccountModel")
                .style(.largeHeader, foreground: .primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom)

            Form {
                Section {
                    Picker("Blockchain", selection: $selectedBlockchain) {
                        ForEach(blockchains, id: \.self) { blockchain in
                            Text(blockchain.name).tag(blockchain)
                        }
                    }

                    Picker("Network", selection: $selectedNetwork) {
                        ForEach(networks, id: \.self) { blockchain in
                            Text("\(blockchain.name) \(blockchain.networkName)").tag(blockchain)
                        }
                    }

                    if case .sui = selectedBlockchain {
                        Picker("Key Scheme", selection: $selectedKeyScheme) {
                            ForEach(Curve.allCases, id: \.self) { scheme in
                                Text(scheme.description).tag(scheme)
                            }
                        }
                    }
                }

                if keyStore.isWatchOnly {
                    Section {
                        TextField("Watch Address", text: $address)
                            .disabled(selectedNetwork == nil)
                            .padding()
                    }
                }
            }
            .padding(.bottom)

            buttonsView
        }
        .padding()
        .alert("Error", isPresented: $isAlertPresented) {
            Button("OK") {
                isAlertPresented = false
                dismiss()
            }
        } message: {
            Text(alertMessage(error))
        }
        .onChange(of: selectedBlockchain, initial: true) { _, newValue in
            didSelectBlockchain(newValue)
        }
    }
}

// MARK: - Subviews

private extension AddAccountView {
    var buttonsView: some View {
        HStack {
            Spacer()

            Button {
                dismiss()
            } label: {
                Text("Cancel")
            }

            Button {
                Task {
                    do {
                        try await addAccount(selectedNetwork!, signatureScheme: selectedKeyScheme)
                    } catch {
                        self.error = error
                        isAlertPresented = true
                    }
                }
            } label: {
                Text("Add AccountModel")
            }
            .disabled(selectedNetwork == nil)
        }
    }
}

// MARK: - Logic

private extension AddAccountView {
    @MainActor
    func addAccount(_ blockchain: WKBlockchain, signatureScheme: Curve?) async throws {
        let accountService = DI.injectOrFail(AccountService.self)
        let account = try await accountService.makeAccount(blockchain, keyStore: keyStore)
        sidebarSelection.wrappedValue = account.id
        dismiss()
    }

    func alertMessage(_ error: Swift.Error?) -> String {
        guard let error else {
            return "Unknown Error."
        }

        switch error {
        case Error.alreadyExists:
            return "AccountModel already exists."
        default:
            return error.localizedDescription
        }
    }

    func didSelectBlockchain(_ blockchain: WKBlockchain?) {
        if let blockchain {
            networks = blockchain.allNetworks
            selectedNetwork = networks.first

            if case .sui = blockchain {
                selectedKeyScheme = .ed25519
            } else {
                selectedKeyScheme = nil
            }
        }
    }
}

// MARK: - Preview

/* #Preview {
    AddAccountView(keyStore: try! KeyStore(model: .mockWatchOnly())) // swiftlint:disable:this force_try
        .frame(width: 400)
} */
