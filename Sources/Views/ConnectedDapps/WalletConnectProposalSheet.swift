//
//  WalletConnectProposalSheet.swift
//  Reefr Wallet
//
//  Created by Andrey Yurkevich on 17.10.26.
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import SwiftUI

/// The session-proposal prompt: who is asking, and which account to give
/// them on each requested network.
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
                        makeChoiceRow(choice)
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

    func makeChoiceRow(_ choice: WalletConnectChainChoice) -> some View {
        HStack {
            VStack(alignment: .leading) {
                Text(choice.blockchain.displayName)
                    .style(.medium)

                if choice.isRequired {
                    Text("Required")
                        .style(.caption, foreground: .secondary)
                }
            }

            Spacer()

            if choice.accounts.isEmpty {
                Text("No account")
                    .style(.small, foreground: .secondary)
            } else {
                Picker("Account", selection: selection(for: choice)) {
                    ForEach(choice.accounts) { account in
                        Text(account.name).tag(Optional(account))
                    }
                }
                .labelsHidden()
                .fixedSize()
            }
        }
    }

    func selection(for choice: WalletConnectChainChoice) -> Binding<Account?> {
        Binding(
            get: { choice.selected },
            set: { account in
                if let account {
                    walletConnect.updateSelection(chain: choice.chain, account: account)
                }
            }
        )
    }
}
