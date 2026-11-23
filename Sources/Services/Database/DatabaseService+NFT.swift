//
//  DatabaseService+NFT.swift
//  Reefr Wallet
//
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import BigInt
import Foundation
import SwiftData
import WalletKit

/// An account's NFT scan progress per source.
struct NFTScanState: Equatable, Sendable {
    var lastCompleteScanAt: Date?
    var scannedBlock: UInt64?
    var isSnapshotSource: Bool
}

/// A mint (`from == 0x0`) transfer seen in an account's NFT ledger.
struct NFTMint: Equatable, Sendable {
    let blockHash: String?
    let blockNumber: UInt64
}

/// An NFT whose metadata URI hasn't been resolved yet.
struct NFTMetadataRequest: Sendable {
    let key: String
    let metadataURI: String
}

extension DatabaseService {
    // MARK: - Reading

    func nftAccountKey(account: Account) throws -> String {
        try accountModel(for: account).persistentModelID.stableKey()
    }

    func fetchNFTs(account: Account) throws -> [NFT] {
        let model = try accountModel(for: account)
        let pending = model.nftPendingSends.map(\.pendingSend)
        let source = model.nftScans.first(where: \.isSnapshotSource).flatMap { NFTSourceId(rawValue: $0.source) }
            ?? .walletKit

        return model.nfts
            .compactMap { row -> NFT? in
                guard let reference = row.reference else {
                    return nil
                }

                return NFT(
                    collectionName: row.collectionName,
                    id: row.key,
                    imageURL: row.imageURL.flatMap(NFTMetadataResolver.displayURL),
                    isTransferable: row.isTransferable,
                    metadataURI: row.metadataURI,
                    name: row.name,
                    objectType: row.objectType,
                    quantity: row.quantity,
                    reference: reference,
                    sendState: NFTReconciler.sendState(for: row.key, pending: pending, source: source)
                )
            }
            .sorted { lhs, rhs in
                let last = "\u{10FFFF}"
                let lhsKey = (lhs.collectionName ?? last, lhs.displayName, lhs.id)
                return lhsKey < (rhs.collectionName ?? last, rhs.displayName, rhs.id)
            }
    }

    func fetchNFTScanStates(account: Account) throws -> [NFTSourceId: NFTScanState] {
        try accountModel(for: account).nftScans.reduce(into: [:]) { result, scan in
            guard let source = NFTSourceId(rawValue: scan.source) else {
                return
            }

            result[source] = NFTScanState(
                lastCompleteScanAt: scan.lastCompleteScanAt,
                scannedBlock: scan.scannedBlock,
                isSnapshotSource: scan.isSnapshotSource
            )
        }
    }

    /// The earliest ledger mint of each NFT, by NFT key.
    func fetchNFTMints(account: Account) throws -> [String: NFTMint] {
        let model = try accountModel(for: account)
        let accountKey = try model.persistentModelID.stableKey()
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
            let mint = NFTMint(blockHash: event.blockHash, blockNumber: event.blockNumber)

            if let existing = result[key], existing.blockNumber <= mint.blockNumber {
                return
            }

            result[key] = mint
        }
    }

    func fetchNFTPendingSends(account: Account) throws -> [NFTPendingSend] {
        try accountModel(for: account).nftPendingSends.map(\.pendingSend)
    }

    func fetchNFTMetadataRequests(account: Account, retryAfter: Date) throws -> [NFTMetadataRequest] {
        try accountModel(for: account).nfts.compactMap { row in
            guard row.name == nil || row.imageURL == nil,
                  let uri = row.metadataURI,
                  (row.metadataFailedAt ?? .distantPast) < retryAfter
            else {
                return nil
            }

            return NFTMetadataRequest(key: row.key, metadataURI: uri)
        }
    }

    // MARK: - Snapshots

    /// Writes a complete listing snapshot after applying pending sends to it,
    /// and makes `source` the account's snapshot source.
    func commitNFTListing(
        account: Account,
        source: NFTSourceId,
        holdings: [OwnedNFT],
        position: NFTSnapshotPosition?,
        startedAt: Date
    ) throws {
        let model = try accountModel(for: account)
        try commit(model: model, source: source, holdings: holdings, evidence: .listing(position), startedAt: startedAt)
        try modelContext.save()
    }

    /// Replaces the source's ledger events from `scan.fromBlock` up, recomputes
    /// the holdings from the whole ledger, and writes them as the snapshot —
    /// all in one save, so a failure keeps the previous ledger and rows.
    func commitNFTLedger(account: Account, source: NFTSourceId, scan: NFTLedgerScan, startedAt: Date) throws {
        let model = try accountModel(for: account)
        let accountKey = try model.persistentModelID.stableKey()
        let sourceName = source.rawValue
        let fromBlock = scan.fromBlock

        for event in model.nftTransferEvents where event.source == sourceName && event.blockNumber >= fromBlock {
            modelContext.delete(event)
        }

        var inserted: Set<String> = []

        for event in scan.events where inserted.insert(event.key(accountKey: accountKey)).inserted {
            modelContext.insert(NFTTransferEventModel(account: model, accountKey: accountKey, event: event))
        }

        let ledger = model.nftTransferEvents
            .filter { $0.source == sourceName && $0.blockNumber < fromBlock }
            .compactMap(\.event)
            + scan.events

        let holdings = NFTLedger.holdings(events: ledger, owner: account.address).map { reference, quantity in
            let metadata = scan.metadata[NFTLedger.assetKey(reference)]

            return OwnedNFT(
                collectionName: metadata?.collectionName,
                imageURI: metadata?.imageURI,
                metadataURI: metadata?.metadataURI,
                name: metadata?.name,
                quantity: quantity,
                reference: reference
            )
        }

        try commit(
            model: model,
            source: source,
            holdings: holdings,
            evidence: .ledger(transferKeys: NFTLedger.transferKeys(ledger)),
            startedAt: startedAt,
            scannedBlock: scan.scannedBlock
        )

        try modelContext.save()
    }

    private func commit(
        model: AccountModel,
        source: NFTSourceId,
        holdings: [OwnedNFT],
        evidence: NFTReconciler.Evidence,
        startedAt: Date,
        scannedBlock: UInt64? = nil
    ) throws {
        let accountKey = try model.persistentModelID.stableKey()
        let blockchain = try modelBlockchain(model)
        let pendingModels = model.nftPendingSends
        let result = NFTReconciler.apply(
            holdings: holdings,
            evidence: evidence,
            pending: pendingModels.map(\.pendingSend)
        ) { NFTKey.make(accountKey: accountKey, reference: $0) }

        for pending in pendingModels where result.reflected.contains(pending.txHash) {
            modelContext.delete(pending)
        }

        var rows = Dictionary(model.nfts.map { ($0.key, $0) }) { first, _ in first }

        for owned in result.holdings {
            let key = NFTKey.make(accountKey: accountKey, reference: owned.reference)

            if let row = rows.removeValue(forKey: key) {
                row.update(from: owned, observedAt: startedAt)
            } else {
                modelContext.insert(
                    NFTModel(account: model, key: key, blockchain: blockchain, owned: owned, observedAt: startedAt)
                )
            }
        }

        for row in rows.values {
            modelContext.delete(row)
        }

        let scanKey = accountKey + "|" + source.rawValue

        for scan in model.nftScans {
            scan.isSnapshotSource = scan.key == scanKey
        }

        let scan = model.nftScans.first { $0.key == scanKey } ?? {
            let scan = NFTScanModel(account: model, key: scanKey, source: source.rawValue)
            modelContext.insert(scan)
            return scan
        }()

        scan.isSnapshotSource = true
        scan.lastCompleteScanAt = startedAt
        scan.scannedBlock = scannedBlock ?? scan.scannedBlock
    }

    // MARK: - Metadata

    /// EVM rows with no metadata URI or name yet.
    func fetchNFTsWithoutMetadataURI(account: Account) throws -> [(key: String, reference: NFTReference)] {
        try accountModel(for: account).nfts.compactMap { row in
            guard row.metadataURI == nil, row.name == nil, let reference = row.reference else {
                return nil
            }

            return (row.key, reference)
        }
    }

    func applyNFTMetadataURIs(_ uris: [String: String]) throws {
        for (key, uri) in uris {
            let predicate = #Predicate<NFTModel> { $0.key == key }
            try modelContext.fetch(FetchDescriptor(predicate: predicate)).first?.metadataURI = uri
        }

        try modelContext.save()
    }

    func applyNFTMetadata(key: String, name: String?, imageURL: String?, failedAt: Date?) throws {
        let predicate = #Predicate<NFTModel> { $0.key == key }

        guard let row = try modelContext.fetch(FetchDescriptor(predicate: predicate)).first else {
            return
        }

        row.name = row.name ?? name
        row.imageURL = row.imageURL ?? imageURL
        row.metadataFailedAt = failedAt
        try modelContext.save()
    }

    // MARK: - Pending sends

    func insertNFTPendingSend(account: Account, send: NFTPendingSend) throws {
        let model = try accountModel(for: account)
        modelContext.insert(NFTPendingSendModel(account: model, send: send))
        try modelContext.save()
    }

    /// Marks a send confirmed and takes its quantity off the stored row.
    func confirmNFTPendingSend(txHash: String, position: UInt64?, at date: Date) throws {
        guard let pending = try pendingSendModel(txHash: txHash),
              pending.state != NFTPendingSend.State.confirmed.rawValue
        else {
            return
        }

        pending.state = NFTPendingSend.State.confirmed.rawValue
        pending.confirmedAt = date
        pending.confirmedPosition = position

        let nftKey = pending.nftKey
        let predicate = #Predicate<NFTModel> { $0.key == nftKey }

        if let row = try modelContext.fetch(FetchDescriptor(predicate: predicate)).first {
            let sent = BigUInt(pending.serializedQuantity)

            if row.quantity > sent {
                row.quantity -= sent
            } else {
                modelContext.delete(row)
            }
        }

        try modelContext.save()
    }

    func deleteNFTPendingSend(txHash: String) throws {
        guard let pending = try pendingSendModel(txHash: txHash) else {
            return
        }

        modelContext.delete(pending)
        try modelContext.save()
    }

    func setNFTPendingSendExpirySlot(txHash: String, slot: UInt64) throws {
        guard let pending = try pendingSendModel(txHash: txHash) else {
            return
        }

        pending.expirySlot = slot
        try modelContext.save()
    }

    // MARK: - Helpers

    private func accountModel(for account: Account) throws -> AccountModel {
        guard let accountId = account.id else {
            throw ReefrError.invalidData
        }

        let predicate = #Predicate<AccountModel> { $0.persistentModelID == accountId }

        guard let model = try modelContext.fetch(FetchDescriptor(predicate: predicate)).first else {
            throw ReefrError.notFound
        }

        return model
    }

    private func modelBlockchain(_ model: AccountModel) throws -> String {
        model.blockchain.serialized
    }

    private func pendingSendModel(txHash: String) throws -> NFTPendingSendModel? {
        let predicate = #Predicate<NFTPendingSendModel> { $0.txHash == txHash }
        return try modelContext.fetch(FetchDescriptor(predicate: predicate)).first
    }
}
