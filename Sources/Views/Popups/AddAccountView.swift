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

struct AddAccountView {
    let keyStore: KeyStore

    @State private var address = ""
    @State private var blockchains: [WKBlockchain]
    @State private var error: Swift.Error?
    @State private var isAlertPresented = false
    @State private var networks: [WKBlockchain]

    @State private var customChainId: String
    @State private var selectedBlockchain: WKBlockchain
    @State private var selectedKeyScheme: Curve?
    @State private var selectedNetwork: WKBlockchain?

    @State private var customEndpointURL: String = ""
    @State private var useCustomEndpoint: Bool = false

    @Environment(\.dismiss) private var dismiss
    @Environment(\.sidebarSelection) private var sidebarSelection: Binding<PersistentIdentifier?>

    private let accountService = DI.injectOrFail(AccountService.self)

    init(keyStore: KeyStore) {
        self.keyStore = keyStore

        let blockchains = WKBlockchain.allMainnets
        let selectedBlockchain = blockchains.first!
        let networks = selectedBlockchain.allNetworks

        self.blockchains = blockchains
        self.networks = networks
        self.selectedNetwork = networks.first
        self.selectedBlockchain = selectedBlockchain

        if case let .evm(chain) = selectedBlockchain {
            customChainId = "\(chain.chainId)"
        } else {
            customChainId = ""
        }
    }
}

// MARK: - View

extension AddAccountView: View {
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
                            Text(blockchain.name).tag(blockchain)
                        }
                    }
                    .accessibilityIdentifier("add-account-blockchain-picker")

                    if !selectedBlockchain.isCustomEVM {
                        Picker("Network", selection: $selectedNetwork) {
                            ForEach(networks, id: \.self) { blockchain in
                                Text("\(blockchain.networkName)").tag(blockchain)
                            }
                        }
                        .accessibilityIdentifier("add-account-network-picker")
                    }

                    if selectedBlockchain.isCustomEVM {
                        TextField("ChainId", text: $customChainId)
                            .disabled(!selectedBlockchain.isCustomEVM)
                    } else if case .sui = selectedBlockchain, !keyStore.isWatchOnly {
                        Picker("Key Scheme", selection: $selectedKeyScheme) {
                            ForEach(Curve.allCases, id: \.self) { scheme in
                                Text(scheme.description).tag(scheme)
                            }
                        }
                    }
                }

                Section {
                    let displayedRpcUrl: Binding<String> = .init(get: {
                        if useCustomEndpoint, !customEndpointURL.isEmpty {
                            customEndpointURL
                        } else {
                            selectedNetwork?.rpcURL.absoluteString ?? ""
                        }
                    }, set: { newValue in
                        if useCustomEndpoint {
                            customEndpointURL = newValue
                        }
                    })

                    let customRPCEnabled: Binding<Bool> = .init(
                        get: { selectedBlockchain.isCustomEVM || useCustomEndpoint },
                        set: { useCustomEndpoint = $0 }
                    )

                    TextField("RPC URL", text: displayedRpcUrl)
                        .disabled(!customRPCEnabled.wrappedValue)
                        .padding(.top)

                    Toggle(isOn: customRPCEnabled) {
                        Text("Custom RPC Endpoint")
                    }
                    .disabled(selectedBlockchain.isCustomEVM)
                }

                if keyStore.isWatchOnly {
                    Section {
                        TextField("Watch Address", text: $address)
                            .disabled(selectedNetwork == nil)
                            .padding(.vertical)
                            .accessibilityIdentifier("add-account-watch-address-field")
                    }
                }
            }
            .padding(.bottom)

            Spacer()

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
        .onChange(of: selectedNetwork) {
            if case let .evm(network) = selectedNetwork {
                customChainId = "\(network.chainId)"
            } else {
                customChainId = ""
            }
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
                        if case .evm(.custom) = selectedBlockchain {
                            guard let chainId = UInt64(customChainId) else {
                                throw Error.invalidData
                            }

                            try await addAccount(.evm(.custom(chainId)), signatureScheme: selectedKeyScheme)
                        } else {
                            try await addAccount(selectedNetwork!, signatureScheme: selectedKeyScheme)
                        }
                    } catch {
                        self.error = error
                        isAlertPresented = true
                    }
                }
            } label: {
                Text("Add Account")
            }
            .disabled(isAddButtonDisabled)
            .accessibilityIdentifier("add-account-submit-button")
        }
    }
}

// MARK: - Logic

private extension AddAccountView {
    var isAddButtonDisabled: Bool {
        guard let selectedNetwork else {
            return true
        }

        return keyStore.isWatchOnly && !accountService.isValidAddress(trimmedAddress, for: selectedNetwork)
    }

    var trimmedAddress: String {
        address.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @MainActor
    func addAccount(_ blockchain: WKBlockchain, signatureScheme: Curve?) async throws {
        let watchOnlyAddress = keyStore.isWatchOnly ? trimmedAddress : nil
        let account = try await accountService.makeAccount(
            blockchain,
            keyStore: keyStore,
            signatureScheme: signatureScheme,
            watchOnlyAddress: watchOnlyAddress
        )
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

            if case let .evm(network) = selectedBlockchain {
                customChainId = "\(network.chainId)"
            } else {
                customChainId = ""
            }
        }
    }
}

// MARK: - Preview

#Preview {
    let keyStore = KeyStore(
        deviceId: nil,
        kind: .watchOnly,
        name: "Key Store",
        rawKey: nil,
        transport: nil,
        vendor: nil
    )

    AddAccountView(keyStore: keyStore)
        .frame(width: 400)
}
