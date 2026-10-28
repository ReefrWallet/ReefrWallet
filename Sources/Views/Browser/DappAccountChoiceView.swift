//
//  DappAccountChoiceView.swift
//  Reefr Wallet
//
//  Created by Andrey Yurkevich on 27.10.26.
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import SwiftUI

/// The first connect prompt of a dapp: one account drop-down per chain it
/// asked to connect on, preselected. Approving connects it with those
/// accounts and remembers them.
struct DappAccountChoiceView: View {
    let selections: [DappAccountSelection]
    let site: String
    let onChoose: ([DappNamespace: Account]) -> Void
    let onReject: () -> Void

    /// Per chain: the account picked, or `nil` for "Not connected". Unset chains use their preselection.
    @State private var picked: [DappNamespace: DappAccountChoice?] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Connect Request")
                .style(.largeHeader)
                .accessibilityIdentifier("dapp-request-title")

            ParameterSection {
                ParameterRow("Site", value: site)

                ForEach(selections) { selection in
                    ParameterRow(selection.namespace.displayName) {
                        Picker(selection.namespace.displayName, selection: binding(for: selection)) {
                            // With several chains on offer, the dapp may be left unconnected on some.
                            if selections.count > 1 {
                                Text("Not connected").tag(DappAccountChoice?.none)
                            }

                            ForEach(selection.choices) { choice in
                                Text(choice.label).tag(Optional(choice))
                            }
                        }
                        .labelsHidden()
                        .accessibilityIdentifier("dapp-account-picker-\(selection.namespace.rawValue)")
                    }
                }
            }

            Text("This site is requesting to connect. It will remember your choice.")
                .style(.small, foreground: .secondary)
                .padding(.top, 4)

            HStack {
                Spacer()

                Button("Reject", action: onReject)
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("dapp-reject-button")

                Button("Approve") {
                    onChoose(Dictionary(uniqueKeysWithValues: selections.compactMap { selection in
                        choice(for: selection).map { (selection.namespace, $0.account) }
                    }))
                }
                .buttonStyle(.borderedProminent)
                .disabled(selections.allSatisfy { choice(for: $0) == nil })
                .accessibilityIdentifier("dapp-approve-button")
            }
        }
        .padding(20)
#if os(macOS)
        .frame(width: 480)
#endif
    }

    private func choice(for selection: DappAccountSelection) -> DappAccountChoice? {
        picked[selection.namespace] ?? selection.defaultChoice
    }

    private func binding(for selection: DappAccountSelection) -> Binding<DappAccountChoice?> {
        Binding(
            get: { choice(for: selection) },
            set: { picked[selection.namespace] = $0 }
        )
    }
}
