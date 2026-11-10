//
//  AccountAddressesView.swift
//  Reefr Wallet
//
//  Created by Andrey Yurkevich on 07.11.26.
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import BigInt
import SwiftData
import SwiftUI

/// A Cardano account's receive addresses, as stored by the last refresh.
struct AccountAddressesView: View {
    let account: Account

    @State private var isRefreshing = false

    @Query private var models: [ReceiveAddressModel]

    init(_ account: Account) {
        guard let accountId = account.id else {
            preconditionFailure()
        }

        self.account = account

        _models = Query(
            filter: #Predicate<ReceiveAddressModel> { $0.account.id == accountId },
            sort: [SortDescriptor(\.index)]
        )
    }

    var body: some View {
        let rows = models.map(ReceiveAddress.init(model:))

        Group {
            #if os(iOS)
            ForEach(rows) { row in
                ReceiveAddressRow(address: row)
            }

            footnote
                .listRowSeparator(.hidden)
            #else
            Table(rows) {
                TableColumn(Text(verbatim: "#")) { row in
                    Text(verbatim: "\(row.index)")
                        .style(.medium, foreground: .secondary)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .accessibilityIdentifier("receive-address-row-\(row.index)")
                }
                .width(min: 24, ideal: 32, max: 48)

                TableColumn(.addressesAddress) { row in
                    Text(row.address)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .style(.mono, foreground: .primary)
                }

                TableColumn(.balancesBalance) { row in
                    ReceiveAddressAmount(address: row)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
                .width(min: 80, ideal: 140)
            }
            .contextMenu(forSelectionType: ReceiveAddress.ID.self) { ids in
                if let row = rows.first(where: { ids.contains($0.id) }) {
                    Button(.accountDetailsCopyAddress) {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(row.address, forType: .string)
                    }
                }
            }
            .statusBar(edge: .top) {
                Text(.addressesReceiveAddresses)
                    .style(.mediumHeader, foreground: .primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading)
                    .padding(.bottom, 8)
            }
            .statusBar {
                footnote
                    .padding([.horizontal, .top], 16)
                    // The macOS tab container adds 3 pt below its content.
                    .padding(.bottom, 13)
            }
            #endif
        }
        .task(id: account.id) {
            await discoverIfNeeded()
        }
    }

    private var footnote: some View {
        Text(isPhone ? .addressesFootnotePhone : .addressesFootnoteMac)
            .style(.small, foreground: .secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Lists row 0 offline, then runs one refresh if discovery has never succeeded.
    private func discoverIfNeeded() async {
        let databaseService = DI.injectOrFail(DatabaseService.self)

        try? await ReceiveAddressService(databaseService: databaseService).ensureBaseRow(for: account)

        guard
            let accountId = account.id,
            !isRefreshing,
            (try? await databaseService.receiveAddressesObservedAt(accountId: accountId)) == nil
        else {
            return
        }

        isRefreshing = true
        await AccountRefresh.run([account])
        isRefreshing = false
    }
}

// MARK: - Preview

#Preview("Addresses") {
    // swiftlint:disable force_try
    let container = try! ModelContainer(
        for: AccountModel.self,
        configurations: ModelConfiguration(isStoredInMemoryOnly: true)
    )

    let context = ModelContext(container)
    let keyStore = KeyStoreModel(.watchOnly, name: "Trezor Safe 5")
    let blockchain = try! BlockchainModel(blockchain: .cardano(.mainnet))
    let account = AccountModel(
        address: "cardano:mainnet:preview",
        blockchain: blockchain,
        keyStore: keyStore,
        name: "Cardano #1"
    )

    // swiftlint:enable force_try

    context.insert(account)

    let amounts: [(Bool?, BigUInt?)] = [
        (true, 147_300_064), (true, 1_159_390), (true, 750_000_000), (true, 1_194_251_270),
        (false, 0), (false, 0), (nil, nil), (false, 0)
    ]

    for (index, entry) in amounts.enumerated() {
        context.insert(ReceiveAddressModel(
            account: account,
            address: "addr1q8k2d4fx\(index)xyz7m7ghv3zqwertyuiop",
            index: index,
            isUsed: entry.0,
            lovelace: entry.1
        ))
    }

    try? context.save()

    var previewAccount = Account(
        address: account.address,
        blockchain: .cardano(.mainnet),
        derivationPath: nil,
        keyStoreId: keyStore.persistentModelID,
        name: "Cardano #1"
    )

    previewAccount.id = account.persistentModelID

    #if os(iOS)
    return List { AccountAddressesView(previewAccount) }
        .listStyle(.plain)
        .modelContainer(container)
    #else
    return AccountAddressesView(previewAccount)
        .modelContainer(container)
    #endif
}
