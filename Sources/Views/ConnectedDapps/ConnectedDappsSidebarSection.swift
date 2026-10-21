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
                        .style(foreground: sidebarSelection.wrappedValue == dapp.id ? .white : .sidebarLabel)
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
                    Image("walletConnect16")
                        .frame(width: 20, height: 20)

                    Text("WalletConnect")
                        .style(foreground: sidebarSelection.wrappedValue == hub.id ? .white : .sidebarLabel)

                    Spacer()

                    if !walletConnect.sessions.isEmpty {
                        Text("\(walletConnect.sessions.count)")
                            .style(
                                .small,
                                foreground: sidebarSelection.wrappedValue == hub.id ? .white : .sidebarSecondaryLabel
                            )
                    }
                }
                .tag(hub.id)
                .accessibilityIdentifier("sidebar-walletconnect")
            }
        } header: {
            HStack {
                Text(title)
                    .style(foreground: .sidebarSecondaryLabel)

                Spacer()

                SidebarAddButton(accessibilityLabel: "Add dApp", accessibilityId: "sidebar-add-dapp-button") {
                    presentSheet?(.addBrowserDapp)
                }
            }
        }
        .task {
            store.ensureWalletConnectHub()
        }
    }
}
