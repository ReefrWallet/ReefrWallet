//
//  AccountTokensView.swift
//  Reefr Wallet
//
//  Created by Andrey Yurkevich on 14.11.26.
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import SwiftData
import SwiftUI

/// Non-native tokens stored for the account's blockchain; balance refreshes read only these.
struct AccountTokensView: View {
    @Query private var models: [TokenModel]

    init(_ account: Account) {
        let serializedBlockchain = (try? account.blockchain.asJSONString()) ?? ""

        _models = Query(
            filter: #Predicate<TokenModel> { !$0.isNativeToken && $0.blockchain?.serialized == serializedBlockchain },
            sort: [SortDescriptor(\.symbol)]
        )
    }

    var body: some View {
        let tokens = models.map(Token.init(model:))
        let countText = String(localized: .tokensTokenCount(tokens.count))

        #if os(iOS)
        AccountCountLabel(text: countText)

        ForEach(tokens) { token in
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(verbatim: token.symbol)
                            .style(.headline, foreground: token.isHidden ? .secondary : .primary)

                        Text(verbatim: token.name)
                            .style(.callout, foreground: .secondary)
                            .lineLimit(1)
                    }

                    Text(verbatim: token.address ?? "")
                        .style(.mono, foreground: .secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer()

                Button {
                    setHidden(token, !token.isHidden)
                } label: {
                    Image(systemName: token.isHidden ? "eye.slash" : "eye")
                        .style(.large, foreground: token.isHidden ? .secondary : .accentColor)
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(.tokensHidden)
                .accessibilityAddTraits(token.isHidden ? .isSelected : [])
                .accessibilityIdentifier("token-hidden-toggle-\(token.id)")
            }
            .padding(.vertical, 4)
            .accessibilityIdentifier("token-row-\(token.id)")
        }
        #else
        Table(tokens) {
            TableColumn(.tokensHidden) { token in
                Toggle(isOn: Binding(get: { token.isHidden }, set: { setHidden(token, $0) })) {
                    Text(.tokensHidden)
                }
                .labelsHidden()
                .toggleStyle(.checkbox)
                .frame(maxWidth: .infinity)
                .accessibilityIdentifier("token-hidden-toggle-\(token.id)")
            }
            .width(50)

            TableColumn(.tokensSymbol) { token in
                Text(verbatim: token.symbol)
                    .style(.medium, foreground: .primary)
                    .accessibilityIdentifier("token-row-\(token.id)")
            }
            .width(min: 60, ideal: 90)

            TableColumn(.tokensName) { token in
                Text(verbatim: token.name)
                    .style(.medium, foreground: .primary)
            }
            .width(min: 90, ideal: 180)

            TableColumn(.tokensAddress) { token in
                Text(verbatim: token.address ?? "")
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .style(.mono, foreground: .secondary)
                    .help(token.address ?? "")
            }
        }
        .contextMenu(forSelectionType: Token.ID.self) { ids in
            if let address = tokens.first(where: { ids.contains($0.id) })?.address {
                Button(.accountDetailsCopyAddress) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(address, forType: .string)
                }
            }
        }
        .statusBar(edge: .top) {
            Text(verbatim: countText)
                .accessibilityIdentifier("account-tokens-count")
                .style(.mediumHeader, foreground: .primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading)
                .padding(.bottom, 8)
        }
        #endif
    }

    private func setHidden(_ token: Token, _ isHidden: Bool) {
        Task {
            do {
                try await DI.injectOrFail(DatabaseService.self).setTokenHidden(token, isHidden: isHidden)
            } catch {
                printError(error)
            }
        }
    }
}

/// Unique within one blockchain.
extension Token: Identifiable {
    var id: String { address ?? "native" }
}
