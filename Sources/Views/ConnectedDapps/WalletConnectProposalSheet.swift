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
        DappConnectionRequestView(
            iconURL: pending.proposal.iconURL,
            ids: .init(
                approve: "walletconnect-proposal-approve",
                reject: "walletconnect-proposal-reject",
                title: "walletconnect-proposal-title"
            ),
            name: pending.proposal.name,
            onApprove: { Task { await walletConnect.approveProposal(selection: pending) } },
            onReject: { Task { await walletConnect.rejectProposal() } },
            url: pending.proposal.url,
            verification: pending.proposal.verification,
            rows: {
                ForEach(pending.choices) { choice in
                    ParameterSection(footer: String(localized: .walletConnectProposalBlockchains(chainNames(choice)))) {
                        ParameterRow(displayName(choice)) {
                            accountPicker(choice)
                        }
                    }
                }
        }
        )
    }
}

private extension WalletConnectProposalSheet {
    @ViewBuilder
    func accountPicker(_ choice: WalletConnectNamespaceChoice) -> some View {
        if choice.accounts.isEmpty {
            Text(.walletConnectProposalNoAccount)
                .style(.small, foreground: .secondary)
        } else {
            Picker(.commonAccount, selection: selection(for: choice)) {
                ForEach(choice.accounts) { account in
                    Text(verbatim: choice.label(for: account)).tag(Optional(account))
                }
            }
            .labelsHidden()
        }
    }

    /// The chain family's name, e.g. "Ethereum" for `eip155`.
    func displayName(_ choice: WalletConnectNamespaceChoice) -> String {
        choice.chains.first.flatMap { DappNamespace.namespace(for: $0.blockchain)?.displayName } ?? choice.namespace
    }

    func chainNames(_ choice: WalletConnectNamespaceChoice) -> String {
        choice.chains
            .filter { !$0.blockchain.isCustomEVM }
            .map(\.blockchain.name)
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
