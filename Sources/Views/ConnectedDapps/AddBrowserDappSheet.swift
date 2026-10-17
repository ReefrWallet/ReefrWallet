//
//  AddBrowserDappSheet.swift
//  Reefr Wallet
//
//  Created by Andrey Yurkevich on 17.10.26.
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import SwiftData
import SwiftUI

/// Adds a dapp URL to the sidebar's Connected dApps list.
struct AddBrowserDappSheet: View {
    @State private var text = ""

    @Environment(\.dismiss) private var dismiss
    @Environment(\.sidebarSelection) private var sidebarSelection: Binding<PersistentIdentifier?>

    private let store = DI.injectOrFail(ConnectedDappStore.self)

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add dApp")
                .style(.largeHeader)

            TextField("https://app.example.com", text: $text)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("add-dapp-url-field")
                .onSubmit(add)

            Spacer()

            HStack {
                Spacer()

                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Button("Add", action: add)
                    .keyboardShortcut(.defaultAction)
                    .disabled(url == nil)
                    .accessibilityIdentifier("add-dapp-add-button")
            }
        }
        .padding()
        .frame(minWidth: 380, minHeight: 160)
    }

    private var url: URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidate = trimmed.contains("://") ? trimmed : "https://\(trimmed)"

        guard let url = URL(string: candidate), url.host() != nil, ["http", "https"].contains(url.scheme) else {
            return nil
        }

        return url
    }

    private func add() {
        guard let url else {
            return
        }

        sidebarSelection.wrappedValue = store.addBrowserDapp(url: url).id
        dismiss()
    }
}
