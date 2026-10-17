//
//  ConnectedDappsSidebarSection.swift
//  Reefr Wallet
//
//  Created by Andrey Yurkevich on 17.10.26.
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import SwiftData
import SwiftUI

private let browserRawKind = ConnectedDappKind.browser.rawValue
private let walletConnectRawKind = ConnectedDappKind.walletConnect.rawValue

/// The sidebar's "Connected dApps" section: browser dapps and the
/// "WalletConnect" entry.
struct ConnectedDappsSidebarSection: View {
    let title: LocalizedStringKey

    @Environment(\.presentSheet) private var presentSheet
    @Environment(\.sidebarSelection) private var sidebarSelection: Binding<PersistentIdentifier?>

    @Query(filter: #Predicate<ConnectedDappModel> { $0.kindRaw == browserRawKind }, sort: \ConnectedDappModel.name)
    private var browserDapps: [ConnectedDappModel]

    @Query(filter: #Predicate<ConnectedDappModel> { $0.kindRaw == walletConnectRawKind })
    private var walletConnectHubs: [ConnectedDappModel]

    private let store = DI.injectOrFail(ConnectedDappStore.self)
    private let walletConnect = DI.injectOrFail(WalletConnectService.self)

    init(_ title: LocalizedStringKey) {
        self.title = title
    }

    var body: some View {
        Section {
            ForEach(browserDapps) { dapp in
                HStack(spacing: 8) {
                    DappIconView(url: dapp.iconURL)

                    Text(dapp.name)
                        .lineLimit(1)
                }
                .tag(dapp.id)
                .contextMenu {
                    Button("Remove", role: .destructive) {
                        if sidebarSelection.wrappedValue == dapp.id {
                            sidebarSelection.wrappedValue = nil
                        }

                        store.remove(dapp)
                    }
                }
                .accessibilityIdentifier("sidebar-connected-dapp-\(dapp.host)")
            }

            if let hub = walletConnectHubs.first {
                HStack(spacing: 8) {
                    Image(systemName: "link")
                        .frame(width: 20, height: 20)

                    Text("WalletConnect")

                    Spacer()

                    if !walletConnect.sessions.isEmpty {
                        Text("\(walletConnect.sessions.count)")
                            .style(.small, foreground: .secondary)
                    }
                }
                .tag(hub.id)
                .accessibilityIdentifier("sidebar-walletconnect")
            }
        } header: {
            HStack {
                Text(title)

                Spacer()

                Button {
                    presentSheet?(.addBrowserDapp)
                } label: {
                    Image(systemName: "plus")
                        .imageScale(.small)
                        .fontWeight(.semibold)
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .padding(.trailing, 6)
                .accessibilityLabel("Add dApp")
                .accessibilityIdentifier("sidebar-add-dapp-button")
            }
        }
        .task {
            store.ensureWalletConnectHub()
        }
    }
}
