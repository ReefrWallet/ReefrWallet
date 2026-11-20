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
        DappConnectionRequestView(
            iconURL: iconURL,
            ids: .init(approve: "dapp-approve-button", reject: "dapp-reject-button", title: "dapp-request-title"),
            isApproveEnabled: isApproveEnabled,
            name: host,
            onApprove: approve,
            onReject: onReject,
            url: site,
            rows: {
                ParameterSection(footer: String(localized: .dappAccountChoiceConnectNote)) {
                    ForEach(selections) { selection in
                        ParameterRow(selection.namespace.displayName) {
                            menu(for: selection)
                        }
                    }
                }
        }
        )
    }
}

// MARK: - Subviews

private extension DappAccountChoiceView {
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
