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
    @State private var blockchains: [Blockchain]
    @State private var error: Swift.Error?
    @State private var isAlertPresented = false
    @State private var networks: [Blockchain]

    @State private var selectedBlockchain: Blockchain?
    @State private var selectedKeyScheme: Curve?
    @State private var selectedNetwork: Blockchain?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.sidebarSelection) private var sidebarSelection: Binding<PersistentIdentifier?>

    let blockchainConfigService = DI.injectOrFail(BlockchainConfigService.self)
//    private lazy var databaseService = DI.injectOrFail(DatabaseService.self)

    init(keyStore: KeyStore) {
        self.keyStore = keyStore

        let blockchains = blockchainConfigService.allBlockchains
        let selectedBlockchain = blockchains.first

        self.blockchains = blockchains

        if let selectedBlockchain {
            self.networks = blockchainConfigService.allNetworks(for: selectedBlockchain)
            self.selectedNetwork = networks.first
        } else {
            self.networks = []
        }

        self.selectedBlockchain = selectedBlockchain
    }
}

// MARK: - View

extension AddAccountView {
    var body: some View {
        VStack {
            Text("Add Blockchain Account")
                .style(.largeHeader, foreground: .primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom)

            Form {
                Section {
                    Picker("Blockchain", selection: $selectedBlockchain) {
                        ForEach(blockchains, id: \.self) { blockchain in
                            let displayName = blockchainConfigService.getDisplayName(for: blockchain) ?? ""
                            Text(displayName).tag(blockchain)
                        }
                    }

                    Picker("Network", selection: $selectedNetwork) {
                        ForEach(networks, id: \.self) { blockchain in
                            let networkName = blockchainConfigService.getNetworkName(for: blockchain) ?? ""
                            Text(networkName).tag(blockchain)
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
                Text("Add Account")
            }
            .disabled(selectedNetwork == nil)
        }
    }
}

// MARK: - Logic

extension AddAccountView {
    @MainActor
    func addAccount(_ blockchain: Blockchain, signatureScheme: Curve?) async throws {
        let accountService = DI.injectOrFail(AccountService.self)
        let account = try await accountService.makeAccount(blockchain, keyStore: keyStore)

        if keyStore.isWatchOnly {
            func setWatchOnlyAddress(_ account: Account) throws {
                switch account.blockchainConfig.blockchain {
                case .ethereum:
                    _ = try EthereumAddress(string: address)
                    account.address = address
                case .sui:
                    _ = try SuiAddress(string: address)
                    account.address = address
                default:
                    throw Error.notImplemented
                }
            }
        }

        sidebarSelection.wrappedValue = account.id
        dismiss()
    }

    func alertMessage(_ error: Swift.Error?) -> String {
        guard let error else {
            return "Unknown Error."
        }

        switch error {
        case Error.alreadyExists:
            return "Account already exists."
        default:
            return error.localizedDescription
        }
    }

    func didSelectBlockchain(_ blockchain: Blockchain?) {
        if let blockchain {
            networks = blockchainConfigService.allNetworks(for: blockchain)
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

#Preview {
    AddAccountView(keyStore: .mockWatchOnly())
        .frame(width: 400)
}
