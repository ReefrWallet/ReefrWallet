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
        if isIOS {
            phoneBody
        } else {
            macBody
        }
    }

    private var phoneBody: some View {
        Form {
            Section {
                HStack(spacing: 12) {
                    DappIconView(url: pending.proposal.iconURL, size: 40)

                    VStack(alignment: .leading) {
                        Text(.walletConnectProposalTitle(pending.proposal.name))
                            .style(.headline, foreground: .primary)
                            .accessibilityIdentifier("walletconnect-proposal-title")

                        Text(verbatim: pending.proposal.url)
                            .style(.caption, foreground: .secondary)
                    }
                }

                verificationBanner
            }

            ForEach(pending.choices) { choice in
                Section {
                    makeChoiceSection(choice)
                }
            }
        }
        .phoneSheet(
            .commonConnect,
            cancelTitle: .commonReject,
            cancelId: "walletconnect-proposal-reject",
            onCancel: { Task { await walletConnect.rejectProposal() } },
            confirmTitle: .commonConnect,
            confirmId: "walletconnect-proposal-approve",
            onConfirm: { Task { await walletConnect.approveProposal(selection: pending) } }
        )
    }

    private var macBody: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                DappIconView(url: pending.proposal.iconURL, size: 40)

                VStack(alignment: .leading) {
                    Text(.walletConnectProposalTitle(pending.proposal.name))
                        .style(.largeHeader)
                        .accessibilityIdentifier("walletconnect-proposal-title")

                    Text(verbatim: pending.proposal.url)
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

                Button(.commonReject) {
                    Task { await walletConnect.rejectProposal() }
                }
                .keyboardShortcut(.cancelAction)
                .accessibilityIdentifier("walletconnect-proposal-reject")

                Button(.commonConnect) {
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
            Label(.walletConnectProposalDomainVerified, systemImage: "checkmark.seal.fill")
                .style(.small, foreground: .green)
        case .invalid:
            Label(.walletConnectProposalDomainMismatch, systemImage: "exclamationmark.triangle.fill")
                .style(.small, foreground: .orange)
        case .unknown:
            Label(.walletConnectProposalDomainUnverified, systemImage: "questionmark.circle")
                .style(.small, foreground: .secondary)
        case .scam:
            Label(.walletConnectProposalDomainMalicious, systemImage: "xmark.octagon.fill")
                .style(.small, foreground: .red)
        }
    }

    func makeChoiceSection(_ choice: WalletConnectNamespaceChoice) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(.walletConnectProposalDefaultAccount)
                    .style(.medium)

                Spacer()

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
                    .fixedSize()
                }
            }

            Text(.walletConnectProposalBlockchains(chainNames(choice)))
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
