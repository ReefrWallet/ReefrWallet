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

    @Environment(\.modelContext) private var modelContext
    @Environment(\.openWindow) private var openWindow

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
                }
            }

            Section("Access") {
                if dapp.grants.isEmpty {
                    Text("Not connected. Open it in the browser to connect.")
                        .style(.medium, foreground: .secondary)
                } else {
                    ForEach(dapp.grants, id: \.self) { grant in
                        LabeledContent(grant.namespace.capitalized) {
                            Text(grant.accountAddress)
                                .style(.smallMono)
                                .textSelection(.enabled)
                        }
                    }
                }
            }

            Section {
                HStack {
                    Button("Open in Browser", action: open)
                        .accessibilityIdentifier("dapp-open-button")

                    Button("Disconnect") {
                        dapp.grants = []
                        try? modelContext.save()
                    }
                    .disabled(dapp.grants.isEmpty)
                    .accessibilityIdentifier("dapp-disconnect-button")

                    Button("Remove", role: .destructive) {
                        store.remove(dapp)
                    }
                    .accessibilityIdentifier("dapp-remove-button")
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(dapp.name)
    }

    private func open() {
#if os(macOS)
        openWindow(id: "browser")
#endif
    }
}
