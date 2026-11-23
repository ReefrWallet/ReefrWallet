//
//  DatabaseService+DefiPosition.swift
//  Reefr Wallet
//
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import Foundation
import SwiftData
import WalletKit

/// DeFi plugin records. See ADR-073.
extension DatabaseService {
    // MARK: - Reading

    /// The account's records, of one kind or (`nil`) all.
    func fetchDefiPositions(account: Account, kind: DefiPluginKind? = nil) throws -> [DefiPosition] {
        try defiAccountModel(for: account).defiPositions
            .filter { kind == nil || $0.serializedKind == kind?.rawValue }
            .compactMap(DefiPosition.init(model:))
            .sorted { ($0.kind.rawValue, $0.key) < ($1.kind.rawValue, $1.key) }
    }

    // MARK: - Writing

    /// Applies a plugin run's outcomes in one save. Rows not named in `outcomes` are left alone.
    func saveDefiOutcomes(
        account: Account,
        kind: DefiPluginKind,
        _ outcomes: [DefiPositionOutcome],
        now: Date = .now
    ) throws {
        let model = try defiAccountModel(for: account)
        let accountKey = try model.persistentModelID.stableKey()
        var rows = Dictionary(
            model.defiPositions
                .filter { $0.serializedKind == kind.rawValue }
                .map { ($0.key, $0) }
        ) { first, _ in first }

        for outcome in outcomes {
            switch outcome {
            case .failed:
                continue

            case let .removed(key):
                if let row = rows.removeValue(forKey: key) {
                    modelContext.delete(row)
                }

            case let .updated(record):
                if let row = rows[record.key] {
                    row.update(from: record, updatedAt: now)
                } else {
                    let row = DefiPositionModel(
                        account: model,
                        defiPositionId: DefiPosition.makeId(kind: kind, accountKey: accountKey, key: record.key),
                        kind: kind,
                        record: record,
                        updatedAt: now
                    )

                    modelContext.insert(row)
                    rows[record.key] = row
                }
            }
        }

        if modelContext.hasChanges {
            try modelContext.save()
        }
    }

    // MARK: - Private

    private func defiAccountModel(for account: Account) throws -> AccountModel {
        guard let accountId = account.id else {
            throw ReefrError.invalidData
        }

        let predicate = #Predicate<AccountModel> { $0.persistentModelID == accountId }

        guard let model = try modelContext.fetch(FetchDescriptor(predicate: predicate)).first else {
            throw ReefrError.notFound
        }

        return model
    }
}
