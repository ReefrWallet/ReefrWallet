//
//  DatabaseService+ReceiveAddress.swift
//  ReefrWallet
//
//  Created by Andrey Yurkevich on 07/11/2026.
//

import SwiftData
import WalletKit

extension DatabaseService {
    /// Writes a completed read: updates rows in place, inserts new ones, never deletes.
    func applyReceiveAddresses(
        accountId: PersistentIdentifier,
        rows: [CardanoReceiveAddress],
        observedAt: Date
    ) throws {
        let account = try fetchAccount(accountId)

        var byIndex = Dictionary(uniqueKeysWithValues: account.receiveAddresses.map { ($0.index, $0) })

        for row in rows {
            let index = Int(row.index)

            if let existing = byIndex[index] {
                existing.isUsed = row.isUsed
                existing.serializedLovelace = row.lovelace.serialize()
            } else {
                let model = ReceiveAddressModel(
                    account: account,
                    address: row.address.string,
                    index: index,
                    isUsed: row.isUsed,
                    lovelace: row.lovelace
                )

                modelContext.insert(model)
                byIndex[index] = model
            }
        }

        account.receiveAddressesObservedAt = observedAt
        try modelContext.save()
    }

    func fetchReceiveAddresses(accountId: PersistentIdentifier) throws -> [ReceiveAddress] {
        try modelContext
            .fetch(FetchDescriptor<ReceiveAddressModel>(
                predicate: #Predicate { $0.account.persistentModelID == accountId },
                sortBy: [SortDescriptor(\.index)]
            ))
            .map(ReceiveAddress.init(model:))
    }

    /// Adds `address` at `index` as unchecked. An existing row is left untouched.
    func insertReceiveAddressIfMissing(accountId: PersistentIdentifier, address: String, index: UInt32) throws {
        let account = try fetchAccount(accountId)

        let value = Int(index)

        guard !account.receiveAddresses.contains(where: { $0.index == value }) else {
            return
        }

        modelContext.insert(ReceiveAddressModel(account: account, address: address, index: value))
        try modelContext.save()
    }

    func receiveAddressesObservedAt(accountId: PersistentIdentifier) throws -> Date? {
        try fetchAccountIfPresent(accountId)?.receiveAddressesObservedAt
    }

    // `model(for:)` can return a placeholder for a deleted account, so look it up by predicate.
    private func fetchAccount(_ id: PersistentIdentifier) throws -> AccountModel {
        guard let account = try fetchAccountIfPresent(id) else {
            throw ReefrError.notFound
        }

        return account
    }

    private func fetchAccountIfPresent(_ id: PersistentIdentifier) throws -> AccountModel? {
        try modelContext.fetch(FetchDescriptor<AccountModel>(
            predicate: #Predicate { $0.persistentModelID == id }
        )).first
    }
}
