//
//  WalletConnectSessionsView.swift
//  Reefr Wallet
//
//  Created by Andrey Yurkevich on 17.10.26.
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import SwiftUI

/// Detail pane of the sidebar's "WalletConnect" entry: every live session.
struct WalletConnectSessionsView: View {
    @State private var isConnecting = false

    private let walletConnect = DI.injectOrFail(WalletConnectService.self)

    var body: some View {
        Group {
            if walletConnect.sessions.isEmpty {
                VStack(spacing: 0) {
                    Spacer()

                    EmptyStateView(.walletConnectSessionsNoConnectedApps)
                        .frame(maxHeight: 220)

                    Button(.commonConnectApp) {
                        isConnecting = true
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .accessibilityIdentifier("walletconnect-empty-connect-button")

                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                List(walletConnect.sessions) { session in
                    makeRow(session)
                }
                .accessibilityIdentifier("walletconnect-sessions-list")
            }
        }
        .navigationTitle(.commonWalletconnect)
        .toolbar {
            ToolbarItem {
                Button {
                    isConnecting = true
                } label: {
                    Label(.commonConnectApp, systemImage: "plus")
                }
                .accessibilityIdentifier("walletconnect-connect-button")
            }
        }
        .sheet(isPresented: $isConnecting) {
            ConnectAppSheet()
        }
        .alert(.commonWalletconnect, isPresented: failureBinding, presenting: walletConnect.failureMessage) { _ in
            Button(.commonOk) {}
        } message: { message in
            Text(verbatim: message)
        }
    }
}

private extension WalletConnectSessionsView {
    var failureBinding: Binding<Bool> {
        Binding(
            get: { walletConnect.failureMessage != nil },
            set: { if !$0 { walletConnect.failureMessage = nil } }
        )
    }

    func makeRow(_ session: WalletConnectSessionInfo) -> some View {
        HStack(spacing: 12) {
            DappIconView(url: session.iconURL, size: 32)

            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: session.name)
                    .style(.medium)

                Text(verbatim: URL(string: session.url)?.host() ?? session.url)
                    .style(.small, foreground: .secondary)

                Text(verbatim: chainSummary(session))
                    .style(.caption, foreground: .secondary)
            }

            Spacer()

            Text(.walletConnectSessionsExpiresOn(session.expiry.formatted(date: .abbreviated, time: .omitted)))
                .style(.caption, foreground: .secondary)

            if let url = URL(string: session.url) {
                Button {
                    PreferredBrowser.open(url)
                } label: {
                    Label(.commonOpenInBrowser, systemImage: "safari")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.borderless)
                .help(.commonOpenInBrowser)
                .accessibilityIdentifier("walletconnect-open-in-browser-button")
            }

            Button(.walletConnectSessionsDisconnect, role: .destructive) {
                Task { await walletConnect.disconnect(topic: session.topic) }
            }
            .accessibilityIdentifier("walletconnect-disconnect-button")
        }
    }

    func chainSummary(_ session: WalletConnectSessionInfo) -> String {
        session.accounts
            .compactMap { WalletConnectChain.blockchain(caip2: $0.chain)?.displayName }
            .joined(separator: ", ")
    }
}
