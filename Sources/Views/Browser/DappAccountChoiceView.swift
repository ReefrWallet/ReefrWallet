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
        if isIOS {
            phoneBody
        } else {
            macBody
        }
    }
}

// MARK: - Subviews

private extension DappAccountChoiceView {
    var macBody: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(.commonConnectRequest)
                .style(.largeHeader)
                .accessibilityIdentifier("dapp-request-title")

            ParameterSection {
                ParameterRow(String(localized: .commonSite), value: site)

                ForEach(selections) { selection in
                    ParameterRow(selection.namespace.displayName) {
                        menu(for: selection)
                    }
                }
            }

            Text(.dappAccountChoiceConnectNote)
                .style(.small, foreground: .secondary)
                .padding(.top, 4)

            HStack {
                Spacer()

                Button(.commonReject, action: onReject)
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("dapp-reject-button")

                Button(.commonApprove, action: approve)
                    .buttonStyle(.borderedProminent)
                    .disabled(!isApproveEnabled)
                    .accessibilityIdentifier("dapp-approve-button")
            }
        }
        .padding(20)
#if os(macOS)
        .frame(width: 480)
#endif
    }

    /// Penpot: `Sheet / WalletConnect Proposal` on `Screens / iPhone`.
    var phoneBody: some View {
        Form {
            Section {
                HStack(spacing: 12) {
                    DappIconView(url: iconURL, size: 40)

                    Text(verbatim: host)
                        .style(.headline, foreground: .primary)
                        .lineLimit(1)
                        .accessibilityIdentifier("dapp-request-title")
                }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
            }

            Section {
                ForEach(selections) { selection in
                    LabeledContent {
                        menu(for: selection)
                    } label: {
                        Text(verbatim: selection.namespace.displayName)
                            .style(.callout, foreground: .primary)
                    }
                }
            } header: {
                Text(.dappAccountChoiceAccounts)
            }
        }
        .phoneSheet(
            .commonConnectRequest,
            cancelTitle: .commonReject,
            cancelId: "dapp-reject-button",
            onCancel: onReject,
            confirmTitle: .commonConnect,
            confirmId: "dapp-approve-button",
            isConfirmEnabled: isApproveEnabled,
            onConfirm: approve
        )
        .presentationDetents([.medium, .large])
    }

    func menu(for selection: DappAccountSelection) -> some View {
        AccountChoiceMenu(
            choices: selection.choices,
            // With several chains on offer, the dapp may be left unconnected on some.
            isNoneAllowed: selections.count > 1,
            namespace: selection.namespace,
            selection: binding(for: selection)
        )
    }
}

// MARK: - Logic

private extension DappAccountChoiceView {
    var host: String {
        URL(string: site)?.host() ?? site
    }

    var iconURL: URL? {
        URL(string: "/favicon.ico", relativeTo: URL(string: site))?.absoluteURL
    }

    var isApproveEnabled: Bool {
        !selections.allSatisfy { choice(for: $0) == nil }
    }

    func approve() {
        onChoose(Dictionary(uniqueKeysWithValues: selections.compactMap { selection in
            choice(for: selection).map { (selection.namespace, $0.account) }
        }))
    }

    func binding(for selection: DappAccountSelection) -> Binding<DappAccountChoice?> {
        Binding(
            get: { choice(for: selection) },
            set: { picked[selection.namespace] = $0 }
        )
    }

    func choice(for selection: DappAccountSelection) -> DappAccountChoice? {
        picked[selection.namespace] ?? selection.defaultChoice
    }
}
