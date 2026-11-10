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
    @State private var errorMessage: LocalizedStringResource?
    @State private var isChecking = false
    @State private var text = ""

    @Environment(\.dismiss) private var dismiss
    @Environment(\.sidebarSelection) private var sidebarSelection: Binding<PersistentIdentifier?>

    private let store = DI.injectOrFail(ConnectedDappStore.self)

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
                TextField("", text: $text, prompt: Text("https://app.example.com"))
                    #if os(iOS)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    #endif
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("add-dapp-url-field")
                    .onSubmit(add)
                    .disabled(isChecking)
            } footer: {
                if let errorMessage {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                }
            }
        }
        .phoneSheet(
            .commonAddDapp,
            onCancel: { dismiss() },
            confirmTitle: .commonAdd,
            confirmId: "add-dapp-add-button",
            isConfirmEnabled: url != nil && !isChecking,
            onConfirm: add
        )
    }

    private var macBody: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(.commonAddDapp)
                .style(.largeHeader)

            TextField("", text: $text, prompt: Text("https://app.example.com").foregroundStyle(.secondary))
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("add-dapp-url-field")
                .onSubmit(add)
                .disabled(isChecking)

            if let errorMessage {
                Text(errorMessage)
                    .style(.small, foreground: .red)
            }

            Spacer()

            HStack {
                if isChecking {
                    ProgressView()
                        .controlSize(.small)
                }

                Spacer()

                Button(.commonCancel) {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Button(.commonAdd, action: add)
                    .keyboardShortcut(.defaultAction)
                    .disabled(url == nil || isChecking)
                    .accessibilityIdentifier("add-dapp-add-button")
            }
        }
        .padding()
        .frame(minWidth: 380, minHeight: 160)
    }

    private var url: URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidate = trimmed.contains("://") ? trimmed : "https://\(trimmed)"

        guard
            let url = URL(string: candidate),
            let host = url.host(),
            host.contains(".") || host == "localhost",
            ["http", "https"].contains(url.scheme)
        else {
            return nil
        }

        return url
    }

    private func add() {
        guard let url, !isChecking else {
            return
        }

        errorMessage = nil
        isChecking = true

        Task {
            let isServed = await Self.isServed(url)
            isChecking = false

            guard isServed else {
                errorMessage = .addBrowserDappUnreachable
                return
            }

            sidebarSelection.wrappedValue = store.addBrowserDapp(url: url).id
            dismiss()
        }
    }

    private static func isServed(_ url: URL) async -> Bool {
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.setValue("text/html", forHTTPHeaderField: "Accept")

        guard let (_, response) = try? await URLSession.shared.data(for: request),
              let status = (response as? HTTPURLResponse)?.statusCode
        else {
            return false
        }

        return status < 500
    }
}
