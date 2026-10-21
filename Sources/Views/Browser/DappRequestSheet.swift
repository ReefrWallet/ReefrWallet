//
//  DappRequestSheet.swift
//  Reefr Wallet
//
//  Created by Andrey Yurkevich on 25.09.26.
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import SwiftUI
import WalletKit

/// The generic approval prompt for a ``DappApprovalRequest`` — origin,
/// account, chain, Reject/Approve — with the chain-specific detail
/// dispatched on the request's preview enum (`Browser/Previews/*`).
struct DappRequestSheet: View {
    let request: DappApprovalRequest
    /// Whether the request was approved and is being handled.
    var isProcessing = false
    /// The user's decision, and whether to keep the sheet up while it runs.
    let onResolve: (DappApprovalResult, Bool) -> Void

    @State private var editedFees: Fees?
    @State private var isHardwareAccount = false

#if os(macOS)
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.browserWindowURL) private var browserWindowURL
#endif

    private let databaseService = DI.injectOrFail(DatabaseService.self)

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Divider()
            detail
            if isHardwareAccount {
                Text("You'll be asked to confirm this on your Trezor.")
                    .style(.small, foreground: .secondary)
            }

            Spacer()
            if isProcessing {
                progress
            } else {
                buttons
            }
        }
        .padding()
        .frame(minWidth: 380, minHeight: 240)
        .interactiveDismissDisabled(isProcessing)
        .task {
            isHardwareAccount = (try? await databaseService.fetchKeyStore(id: account.keyStoreId))?.isHardware ?? false
        }
    }
}

// MARK: - Subviews

private extension DappRequestSheet {
    var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .style(.largeHeader)
                .accessibilityIdentifier("dapp-request-title")

            Text(origin)
                .style(.small, foreground: .secondary)

            LabeledContent {
                Text(account.address)
                    .style(.small)
            } label: {
                Text(account.name)
                    .style(.small, foreground: .secondary)
            }
        }
    }

    @ViewBuilder
    var detail: some View {
        switch request {
        case .connect:
            Text("This site is requesting to connect to this account.")
                .style(.medium)
        case let .signMessage(_, _, _, preview):
            switch preview {
            case let .aptosMessage(fullMessage):
                AptosMessagePreviewView(fullMessage: fullMessage)
            case let .ethereumPersonal(message):
                EthereumPersonalPreviewView(message: message)
            case let .ethereumTypedData(summary):
                EthereumTypedDataPreviewView(summary: summary)
            case let .solanaMessage(message):
                SolanaMessagePreviewView(message: message)
            case let .suiPersonal(message):
                SuiPersonalPreviewView(message: message)
            case let .tronMessage(message):
                TronMessagePreviewView(message: message)
            }

        case let .sendTransaction(_, _, account, preview):
            switch preview {
            case let .aptos(preview):
                AptosTransactionPreviewView(preview: preview)

            case let .ethereum(call, fees):
                EthereumCallPreviewView(
                    blockchain: account.blockchain,
                    call: call,
                    estimatedFees: fees,
                    fees: $editedFees
                )

            case let .solana(preview):
                SolanaTransactionPreviewView(preview: preview)

            case let .sui(preview):
                SuiTransactionPreviewView(preview: preview)

            case let .tron(preview):
                TronTransactionPreviewView(preview: preview)
            }
        }
    }

    var buttons: some View {
        HStack {
            Spacer()
            Button("Reject") {
                onResolve(.rejected, false)
            }
            .accessibilityIdentifier("dapp-reject-button")

#if os(macOS)
            Button("Close Browser") {
                // Walking away from the prompt is still a rejection, and the
                // waiting provider has to be told before the window goes.
                onResolve(.rejected, false)

                withTransaction(\.dismissBehavior, .destructive) {
                    dismissWindow(id: "browser", value: browserWindowURL ?? WalletApp.defaultBrowserURL)
                }
            }
            .accessibilityIdentifier("dapp-close-browser-button")
#endif

            Button("Approve") {
                onResolve(approvedResult, isHardwareAccount)
            }
            .accessibilityIdentifier("dapp-approve-button")
        }
    }

    var progress: some View {
        HStack {
            Spacer()
            ProgressView()
                .controlSize(.small)

            Text("Signing...")
                .style(.medium, foreground: .secondary)
        }
    }
}

// MARK: - Logic

private extension DappRequestSheet {
    var account: Account {
        switch request {
        case let .connect(_, _, account): account
        case let .signMessage(_, _, account, _): account
        case let .sendTransaction(_, _, account, _): account
        }
    }

    /// `.approvedWithFees` for a transaction (carrying any fee edits the
    /// user made), `.approved` for every other request kind.
    var approvedResult: DappApprovalResult {
        guard case let .sendTransaction(_, _, _, .ethereum(_, estimatedFees)) = request else {
            return .approved
        }

        return .approvedWithFees(editedFees ?? estimatedFees)
    }

    /// The origin the request actually came from — carried on the
    /// request itself (from `WKSecurityOrigin`) rather than read from
    /// the browser's current URL, so a redirect or a stale tab can't
    /// make this sheet display a different origin than the one the
    /// dapp is being approved for.
    var origin: String {
        switch request {
        case let .connect(origin, _, _): origin
        case let .signMessage(origin, _, _, _): origin
        case let .sendTransaction(origin, _, _, _): origin
        }
    }

    var title: String {
        switch request {
        case .connect: "Connect"
        case .signMessage: "Signature Request"
        case .sendTransaction: "Transaction Request"
        }
    }
}
