//
//  AccountChoiceMenu.swift
//  Reefr Wallet
//
//  Created by Andrey Yurkevich on 02.11.26.
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import SwiftUI

/// A dapp's account on one chain: a pop-up of full labels on macOS; on iOS a
/// menu labelled with the picked account's ``AddressValue``.
struct AccountChoiceMenu: View {
    let choices: [DappAccountChoice]
    /// Whether "Not connected" is offered.
    var isNoneAllowed = true
    let namespace: DappNamespace
    @Binding var selection: DappAccountChoice?

    var body: some View {
#if os(macOS)
        picker
            .labelsHidden()
            .accessibilityIdentifier(accessibilityId)
#else
        Menu {
            picker
                .pickerStyle(.inline)
        } label: {
            HStack(spacing: 6) {
                if let selection {
                    AddressValue(
                        accountName: selection.account.name,
                        address: selection.displayAddress,
                        keyStoreName: selection.keyStoreName.isEmpty ? nil : selection.keyStoreName
                    )
                } else {
                    Text(.commonNotConnected)
                        .style(.callout, foreground: .accentColor)
                }

                Image(systemName: "chevron.down")
                    .imageScale(.small)
                    .style(.callout, foreground: .accentColor)
            }
        }
        .accessibilityIdentifier(accessibilityId)
#endif
    }

    private var accessibilityId: String {
        "dapp-account-picker-\(namespace.rawValue)"
    }

    private var picker: some View {
        Picker(namespace.displayName, selection: $selection) {
            if isNoneAllowed {
                Text(.commonNotConnected).tag(DappAccountChoice?.none)
            }

            ForEach(choices) { choice in
                Text(choice.label).tag(Optional(choice))
            }
        }
    }
}
