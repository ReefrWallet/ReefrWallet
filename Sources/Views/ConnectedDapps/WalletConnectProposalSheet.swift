//
//  WalletConnectProposalSheet.swift
//  Reefr Wallet
//
//  Created by Andrey Yurkevich on 17.10.26.
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import SwiftUI

/// The session-proposal prompt: who is asking, which default account to
/// give them per namespace, and the networks they asked for.
struct WalletConnectProposalSheet: View {
    let pending: WalletConnectPendingProposal

    private let walletConnect = DI.injectOrFail(WalletConnectService.self)

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                DappIconView(url: pending.proposal.iconURL, size: 40)

                VStack(alignment: .leading) {
                    Text("Connect to \(pending.proposal.name)")
                        .style(.largeHeader)
                        .accessibilityIdentifier("walletconnect-proposal-title")

                    Text(pending.proposal.url)
                        .style(.small, foreground: .secondary)
                }
            }

            verificationBanner

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(pending.choices) { choice in
                        makeChoiceSection(choice)
                    }
                }
            }

            HStack {
                Spacer()

                Button("Reject") {
                    Task { await walletConnect.rejectProposal() }
                }
                .keyboardShortcut(.cancelAction)
                .accessibilityIdentifier("walletconnect-proposal-reject")

                Button("Connect") {
                    Task { await walletConnect.approveProposal(selection: pending) }
                }
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("walletconnect-proposal-approve")
            }
        }
        .padding()
        .frame(minWidth: 420, minHeight: 320)
    }
}

private extension WalletConnectProposalSheet {
    @ViewBuilder
    var verificationBanner: some View {
        switch pending.proposal.verification {
        case .valid:
            Label("Verified domain", systemImage: "checkmark.seal.fill")
                .style(.small, foreground: .green)
        case .invalid:
            Label("Domain doesn't match the app's registration", systemImage: "exclamationmark.triangle.fill")
                .style(.small, foreground: .orange)
        case .unknown:
            Label("Couldn't verify this domain", systemImage: "questionmark.circle")
                .style(.small, foreground: .secondary)
        case .scam:
            Label("Flagged as malicious", systemImage: "xmark.octagon.fill")
                .style(.small, foreground: .red)
        }
    }

    func makeChoiceSection(_ choice: WalletConnectNamespaceChoice) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Default account")
                    .style(.medium)

                Spacer()

                if choice.accounts.isEmpty {
                    Text("No account")
                        .style(.small, foreground: .secondary)
                } else {
                    Picker("Account", selection: selection(for: choice)) {
                        ForEach(choice.accounts) { account in
                            Text(choice.label(for: account)).tag(Optional(account))
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
            }

            Text("Blockchains: \(chainNames(choice))")
                .style(.small, foreground: .secondary)
        }
    }

    func chainNames(_ choice: WalletConnectNamespaceChoice) -> String {
        choice.chains
            .map { $0.blockchain.displayName.replacingOccurrences(of: " Mainnet", with: "") }
            .joined(separator: ", ")
    }

    func selection(for choice: WalletConnectNamespaceChoice) -> Binding<Account?> {
        Binding(
            get: { choice.selected },
            set: { account in
                if let account {
                    walletConnect.updateSelection(namespace: choice.namespace, account: account)
                }
            }
        )
    }
}
