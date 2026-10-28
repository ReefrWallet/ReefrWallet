//
//  BrowserDappDetailsView.swift
//  Reefr Wallet
//
//  Created by Andrey Yurkevich on 17.10.26.
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import SwiftData
import SwiftUI

/// Detail pane for a browser dapp in the sidebar.
struct BrowserDappDetailsView: View {
    let dapp: ConnectedDappModel

    @Environment(\.openWindow) private var openWindow
    @Environment(\.presentSheet) private var presentSheet
    @Query private var accountModels: [AccountModel]
    @Query private var keyStoreModels: [KeyStoreModel]

    private let store = DI.injectOrFail(ConnectedDappStore.self)

    var body: some View {
        Form {
            Section {
                HStack(spacing: 12) {
                    DappIconView(url: dapp.iconURL, size: 40)

                    VStack(alignment: .leading) {
                        Text(dapp.name)
                            .style(.mediumHeader)

                        Text(dapp.urlString)
                            .style(.small, foreground: .secondary)
                    }

                    Spacer()

                    Button("Remove", role: .destructive) {
                        store.remove(dapp)
                    }
                    .accessibilityIdentifier("dapp-remove-button")
                }
            }

            Section("Access") {
                if namespaces.isEmpty {
                    Text("Not connected. Open it in the browser to connect.")
                        .style(.medium, foreground: .secondary)
                } else {
                    ForEach(namespaces, id: \.self) { namespace in
                        accountRow(namespace)
                    }
                }

                HStack {
                    Spacer()

                    Button("Open in Browser") { open() }
                        .accessibilityIdentifier("dapp-open-button")
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(dapp.name)
    }

    /// The chains this dapp asked to connect on, plus any it holds a grant for.
    private var namespaces: [DappNamespace] {
        let names = Set(dapp.requestedNamespaces + dapp.grants.map(\.namespace))

        return names.compactMap(DappNamespace.init(rawValue:)).sorted { $0.displayName < $1.displayName }
    }

    /// One row per chain: the account the dapp connects with on it.
    private func accountRow(_ namespace: DappNamespace) -> some View {
        LabeledContent(namespace.displayName) {
            Picker(namespace.displayName, selection: grantBinding(namespace)) {
                Text("Not connected").tag(String?.none)

                ForEach(choices(for: namespace)) { choice in
                    Text(choice.label).tag(Optional(choice.account.address))
                }
            }
            .labelsHidden()
            .fixedSize()
            .accessibilityIdentifier("dapp-account-picker-\(namespace.rawValue)")
        }
    }

    private func granted(_ namespace: DappNamespace) -> String? {
        dapp.grants.first { $0.namespace == namespace.rawValue }?.accountAddress
    }

    private func grantBinding(_ namespace: DappNamespace) -> Binding<String?> {
        Binding(
            get: { granted(namespace) },
            set: { address in
                guard let address else {
                    store.disconnect(dapp, namespace: namespace.rawValue)
                    return
                }

                store.connect(dapp, accountAddress: address, namespace: namespace.rawValue)
            }
        )
    }

    /// Accounts on `namespace`'s chains.
    private func choices(for namespace: DappNamespace) -> [DappAccountChoice] {
        let names = Dictionary(uniqueKeysWithValues: keyStoreModels.map { ($0.id, $0.name) })

        return accountModels
            .compactMap { model -> DappAccountChoice? in
                guard let account = try? Account(model: model), namespace.matches(account.blockchain) else {
                    return nil
                }

                return DappAccountChoice(account: account, keyStoreName: names[account.keyStoreId] ?? "")
            }
            .sorted { ($0.keyStoreName, $0.account.name) < ($1.keyStoreName, $1.account.name) }
    }

    private func open() {
        guard let url = URL(string: dapp.urlString) else {
            return
        }

#if os(macOS)
        openWindow(id: "browser", value: BrowserWindowTarget(url: url))
#else
        presentSheet?(.browser(url))
#endif
    }
}
