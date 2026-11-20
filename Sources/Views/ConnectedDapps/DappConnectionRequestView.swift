//
//  DappConnectionRequestView.swift
//  Reefr Wallet
//
//  Created by Andrey Yurkevich on 21.11.26.
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import SwiftUI

/// The connect prompt shared by browser dapps and WalletConnect: the dapp's icon,
/// name and address, an optional domain verification, and the caller's account rows.
struct DappConnectionRequestView<Rows: View>: View {
    let iconURL: URL?
    let ids: Ids
    var isApproveEnabled = true
    let name: String
    let onApprove: () -> Void
    let onReject: () -> Void
    let url: String
    /// Shown as a badge; `nil` shows none.
    var verification: WalletConnectVerification?
    @ViewBuilder let rows: Rows

    /// Accessibility identifiers of the title and the two buttons.
    struct Ids {
        let approve: String
        let reject: String
        let title: String
    }

    var body: some View {
        if isIOS {
            phoneBody
        } else {
            macBody
        }
    }
}

// MARK: - Subviews

private extension DappConnectionRequestView {
    var header: some View {
        HStack(spacing: 12) {
            DappIconView(url: iconURL, size: 40)

            VStack(alignment: .leading) {
                Text(.walletConnectProposalTitle(name))
                    .style(isIOS ? .headline : .largeHeader, foreground: .primary)
                    .accessibilityIdentifier(ids.title)

                Text(verbatim: url)
                    .style(.small, foreground: .secondary)
            }
        }
    }

    var macBody: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            verificationBanner

            rows

            HStack {
                Spacer()

                Button(.commonReject, action: onReject)
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier(ids.reject)

                Button(.commonConnect, action: onApprove)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!isApproveEnabled)
                    .accessibilityIdentifier(ids.approve)
            }
        }
        .padding(20)
        .frame(width: 480)
    }

    var phoneBody: some View {
        Form {
            Section {
                header

                verificationBanner
            }

            rows
        }
        .phoneSheet(
            .commonConnect,
            cancelTitle: .commonReject,
            cancelId: ids.reject,
            onCancel: onReject,
            confirmTitle: .commonConnect,
            confirmId: ids.approve,
            isConfirmEnabled: isApproveEnabled,
            onConfirm: onApprove
        )
    }

    @ViewBuilder
    var verificationBanner: some View {
        switch verification {
        case .none:
            EmptyView()
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
}
