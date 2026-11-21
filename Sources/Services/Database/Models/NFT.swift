//
//  NFT.swift
//  Reefr Wallet
//
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import BigInt
import Foundation
import SwiftData
import WalletKit

// MARK: - NFT

/// A non-fungible asset an account holds, as shown in the NFTs tab.
struct NFT: Equatable, Hashable, Identifiable, Sendable {
    let collectionName: String?
    let id: String
    let imageURL: URL?
    let isTransferable: Bool
    let metadataURI: String?
    let name: String?
    let objectType: String?
    /// Held quantity minus confirmed sends not yet reflected by the source.
    let quantity: BigUInt
    let reference: NFTReference
    /// The send state that blocks or annotates this asset, if any.
    let sendState: NFTSendState?

    var displayName: String {
        name ?? "#\(reference.tokenId)"
    }

    /// Whether the quantity row applies: ERC-1155, or more than one held.
    var hasQuantity: Bool {
        reference.standard == .erc1155 || quantity > 1
    }

    /// Whether a search for `query` finds this NFT.
    func matches(_ query: String) -> Bool {
        let query = query.trimmingCharacters(in: .whitespaces)

        return query.isEmpty
            || displayName.localizedCaseInsensitiveContains(query)
            || (collectionName ?? "").localizedCaseInsensitiveContains(query)
            || reference.collection.localizedCaseInsensitiveContains(query)
    }
}

/// An outgoing send's effect on an NFT card.
enum NFTSendState: Equatable, Hashable, Sendable {
    /// Broadcast, outcome unknown; Send stays disabled.
    case unconfirmed
    /// Confirmed, but the ownership source hasn't reflected it for over an hour.
    case waitingForIndex(source: String)
}

/// The key of an account's NFT: unique per standard, collection and token id.
enum NFTKey {
    static func make(accountKey: String, reference: NFTReference) -> String {
        [accountKey, reference.standard.rawValue, reference.collection.lowercased(), reference.tokenId]
            .joined(separator: "|")
    }
}

// MARK: - NFTModel

@Model
final class NFTModel {
    @Attribute(.unique) var key: String
    var blockchain: String
    var collection: String
    var collectionName: String?
    var imageURL: String?
    var isTransferable: Bool
    var metadataFailedAt: Date?
    var metadataURI: String?
    var name: String?
    var objectType: String?
    var observedAt: Date
    var serializedQuantity: Data
    var standard: String
    var tokenId: String
    /// The source version of the holding: a Sui object version or an Aptos
    /// ownership row's `last_transaction_version`.
    var version: UInt64?

    @Relationship(deleteRule: .noAction)
    var account: AccountModel

    init(account: AccountModel, key: String, blockchain: String, owned: OwnedNFT, observedAt: Date) {
        self.account = account
        self.blockchain = blockchain
        self.key = key
        collection = owned.reference.collection
        isTransferable = owned.reference.isTransferable
        self.observedAt = observedAt
        serializedQuantity = owned.quantity.serialize()
        standard = owned.reference.standard.rawValue
        tokenId = owned.reference.tokenId
        update(from: owned, observedAt: observedAt)
    }

    var quantity: BigUInt {
        get { BigUInt(serializedQuantity) }

        set { serializedQuantity = newValue.serialize() }
    }

    var reference: NFTReference? {
        NFTStandard(rawValue: standard).map {
            NFTReference(collection: collection, isTransferable: isTransferable, standard: $0, tokenId: tokenId)
        }
    }

    /// Takes ownership fields from `owned`; listing metadata replaces stored
    /// metadata only when present.
    func update(from owned: OwnedNFT, observedAt: Date) {
        isTransferable = owned.reference.isTransferable
        quantity = owned.quantity
        version = owned.version
        self.observedAt = observedAt
        collectionName = owned.collectionName ?? collectionName
        imageURL = owned.imageURI ?? imageURL
        metadataURI = owned.metadataURI ?? metadataURI
        name = owned.name ?? name
        objectType = owned.objectType ?? objectType
    }
}

// MARK: - NFTScanModel

/// One ownership source's progress for an account.
@Model
final class NFTScanModel {
    /// `accountKey|source`.
    @Attribute(.unique) var key: String
    /// Whether the account's ``NFTModel`` rows came from this source's last snapshot.
    var isSnapshotSource: Bool
    var lastCompleteScanAt: Date?
    /// The newest block a ledger source has scanned.
    var scannedBlock: UInt64?
    var source: String

    @Relationship(deleteRule: .noAction)
    var account: AccountModel

    init(account: AccountModel, key: String, source: String) {
        self.account = account
        self.key = key
        isSnapshotSource = false
        self.source = source
    }
}

// MARK: - NFTTransferEventModel

/// One EVM NFT transfer in a ledger source's replay.
@Model
final class NFTTransferEventModel {
    /// `accountKey|source|txHash|logIndex|batchPosition`.
    @Attribute(.unique) var key: String
    var batchPosition: Int
    var blockHash: String?
    var blockNumber: UInt64
    var contract: String
    var from: String
    var logIndex: Int
    var serializedAmount: Data
    var source: String
    var standard: String
    var to: String
    var tokenId: String
    var transactionIndex: Int
    var txHash: String

    @Relationship(deleteRule: .noAction)
    var account: AccountModel

    init(account: AccountModel, accountKey: String, event: NFTTransferEvent) {
        self.account = account
        key = event.key(accountKey: accountKey)
        batchPosition = event.batchPosition
        blockHash = event.blockHash
        blockNumber = event.blockNumber
        contract = event.contract.lowercased()
        from = event.from.lowercased()
        logIndex = event.logIndex
        serializedAmount = event.amount.serialize()
        source = event.source
        standard = event.standard.rawValue
        to = event.to.lowercased()
        tokenId = event.tokenId
        transactionIndex = event.transactionIndex
        txHash = event.txHash.lowercased()
    }

    var event: NFTTransferEvent? {
        NFTStandard(rawValue: standard).map {
            NFTTransferEvent(
                amount: BigUInt(serializedAmount),
                batchPosition: batchPosition,
                blockHash: blockHash,
                blockNumber: blockNumber,
                contract: contract,
                from: from,
                logIndex: logIndex,
                source: source,
                standard: $0,
                to: to,
                tokenId: tokenId,
                transactionIndex: transactionIndex,
                txHash: txHash
            )
        }
    }
}

/// An EVM NFT transfer, as a ledger source reports it.
struct NFTTransferEvent: Equatable, Sendable {
    let amount: BigUInt
    let batchPosition: Int
    let blockHash: String?
    let blockNumber: UInt64
    let contract: String
    let from: String
    let logIndex: Int
    let source: String
    let standard: NFTStandard
    let to: String
    let tokenId: String
    let transactionIndex: Int
    let txHash: String

    func key(accountKey: String) -> String {
        [accountKey, source, txHash.lowercased(), String(logIndex), String(batchPosition)].joined(separator: "|")
    }

    /// Ledger order: block, transaction, log, batch item.
    static func ledgerOrder(_ lhs: Self, _ rhs: Self) -> Bool {
        (lhs.blockNumber, lhs.transactionIndex, lhs.logIndex, lhs.batchPosition)
            < (rhs.blockNumber, rhs.transactionIndex, rhs.logIndex, rhs.batchPosition)
    }
}

// MARK: - NFTPendingSendModel

/// An outgoing NFT send not yet reflected by the ownership source.
@Model
final class NFTPendingSendModel {
    @Attribute(.unique) var txHash: String
    var broadcastAt: Date
    var confirmedAt: Date?
    var confirmedPosition: UInt64?
    /// Cardano: the `txHash#index` inputs the send consumed; Sui: the sent
    /// object's `id|version|digest` before the send.
    var consumedOutpoints: [String]
    /// Solana: `lastValidBlockHeight`; Aptos: `expiration_timestamp_secs`;
    /// Cardano: the TTL slot.
    var expiry: UInt64?
    /// Solana: the first slot seen past `expiry`, once observed.
    var expirySlot: UInt64?
    var nftKey: String
    /// EVM: the transaction nonce.
    var nonce: UInt64?
    /// Sui: the sent object's version before the send.
    var objectVersion: UInt64?
    var serializedQuantity: Data
    var serializedQuantityBefore: Data
    var state: String

    @Relationship(deleteRule: .noAction)
    var account: AccountModel

    init(account: AccountModel, send: NFTPendingSend) {
        self.account = account
        broadcastAt = send.broadcastAt
        consumedOutpoints = send.consumedOutpoints
        expiry = send.expiry
        expirySlot = send.expirySlot
        nftKey = send.nftKey
        nonce = send.nonce
        objectVersion = send.objectVersion
        serializedQuantity = send.quantity.serialize()
        serializedQuantityBefore = send.quantityBefore.serialize()
        state = send.state.rawValue
        txHash = send.txHash
    }

    var pendingSend: NFTPendingSend {
        NFTPendingSend(
            broadcastAt: broadcastAt,
            confirmedAt: confirmedAt,
            confirmedPosition: confirmedPosition,
            consumedOutpoints: consumedOutpoints,
            expiry: expiry,
            expirySlot: expirySlot,
            nftKey: nftKey,
            nonce: nonce,
            objectVersion: objectVersion,
            quantity: BigUInt(serializedQuantity),
            quantityBefore: BigUInt(serializedQuantityBefore),
            state: NFTPendingSend.State(rawValue: state) ?? .broadcast,
            txHash: txHash
        )
    }
}

struct NFTPendingSend: Equatable, Sendable {
    enum State: String, Sendable {
        case broadcast
        case confirmed
    }

    var broadcastAt: Date
    var confirmedAt: Date?
    var confirmedPosition: UInt64?
    var consumedOutpoints: [String]
    var expiry: UInt64?
    var expirySlot: UInt64?
    var nftKey: String
    var nonce: UInt64?
    var objectVersion: UInt64?
    var quantity: BigUInt
    var quantityBefore: BigUInt
    var state: State
    var txHash: String
}

// MARK: - Blockchain

extension Blockchain {
    /// Chains with an NFTs tab.
    var supportsNFTs: Bool {
        switch self {
        case .aptos, .cardano, .evm, .solana, .sui:
            true
        case .bitcoin, .ton, .tron:
            false
        }
    }
}
