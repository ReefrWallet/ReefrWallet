//
//  DatabaseService+DefiPosition.swift
//  Reefr Wallet
//
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import CryptoKit
import Foundation
import SwiftData
import WalletKit

/// What DeFi plugins read for one account, taken in one fetch. See ADR-073.
struct DefiInput: Sendable {
    let accountKey: String
    /// Mint evidence from the NFT ledger, by NFT key.
    let mints: [String: DefiMintEvidence]
    let nfts: [NFT]
    let positions: [DefiPosition]
    /// Changes whenever ownership or the NFT snapshot changes; metadata doesn't count.
    let revision: String
    let scanStates: [NFTSourceId: NFTScanState]
}

/// A mint (`from == 0x0`) transfer seen in an account's NFT ledger.
struct DefiMintEvidence: Equatable, Sendable {
    let blockHash: String?
    let blockNumber: UInt64
}

extension DatabaseService {
    // MARK: - Reading

    func defiInput(account: Account) throws -> DefiInput {
        let model = try defiAccountModel(for: account)
        let accountKey = try model.persistentModelID.stableKey()

        return try DefiInput(
            accountKey: accountKey,
            mints: Self.defiMints(model: model, accountKey: accountKey),
            nfts: fetchNFTs(account: account),
            positions: model.defiPositions.compactMap(DefiPosition.init(model:)),
            revision: Self.defiRevision(model: model),
            scanStates: fetchNFTScanStates(account: account)
        )
    }

    func fetchDefiPositions(account: Account) throws -> [DefiPosition] {
        try defiAccountModel(for: account).defiPositions
            .compactMap(DefiPosition.init(model:))
            .sorted { ($0.kind.rawValue, $0.key) < ($1.kind.rawValue, $1.key) }
    }

    // MARK: - Writing

    /// Applies a plugin run's outcomes in one save, unless the account's NFT
    /// revision moved since the run read its input. Rows not named in
    /// `outcomes` are left alone.
    ///
    /// - Returns: `false` when the revision changed and nothing was written.
    @discardableResult
    func commitDefiOutcomes(
        account: Account,
        kind: DefiPluginKind,
        outcomes: [DefiPositionOutcome],
        expectedRevision: String,
        now: Date = .now
    ) throws -> Bool {
        let model = try defiAccountModel(for: account)

        guard Self.defiRevision(model: model) == expectedRevision else {
            return false
        }

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

        return true
    }

    // MARK: - Helpers

    /// The snapshot source's completed scan plus the owned rows' keys and
    /// quantities. Metadata writes leave it unchanged.
    static func defiRevision(model: AccountModel) -> String {
        let snapshot = model.nftScans.first(where: \.isSnapshotSource)
        let scan = [
            snapshot?.source ?? "-",
            snapshot?.lastCompleteScanAt.map { String($0.timeIntervalSinceReferenceDate) } ?? "-"
        ]
        let holdings = model.nfts
            .map { "\($0.key)=\($0.quantity)" }
            .sorted()
        let pending = model.nftPendingSends
            .map(\.txHash)
            .sorted()
        let digest = SHA256.hash(data: Data((scan + holdings + ["#"] + pending).joined(separator: "\n").utf8))

        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func defiMints(model: AccountModel, accountKey: String) -> [String: DefiMintEvidence] {
        let zero = "0x" + String(repeating: "0", count: 40)

        return model.nftTransferEvents.reduce(into: [:]) { result, row in
            guard row.from == zero, let event = row.event else {
                return
            }

            let reference = NFTReference(
                collection: event.contract,
                isTransferable: true,
                standard: event.standard,
                tokenId: event.tokenId
            )

            let key = NFTKey.make(accountKey: accountKey, reference: reference)
            let evidence = DefiMintEvidence(blockHash: event.blockHash, blockNumber: event.blockNumber)

            if let existing = result[key], existing.blockNumber <= evidence.blockNumber {
                return
            }

            result[key] = evidence
        }
    }

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
