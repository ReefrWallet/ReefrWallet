//
//  WalletTransaction.swift
//  Reefr Wallet
//

import Foundation
import SwiftData
import WalletKit

/// App-level representation of a transaction stored for one wallet account.
/// The chain payload stays opaque so adding a blockchain never requires a
/// migration just to preserve a new chain-specific field.
struct WalletTransaction: Identifiable, Sendable {
    let id: PersistentIdentifier?
    let accountId: PersistentIdentifier
    let stableID: String
    let chainIdentifier: String
    let blockHeight: UInt64?
    let blockHash: String?
    let timestamp: Date?
    let transactionIndex: UInt64?
    let sender: String?
    let recipient: String?
    let status: BlockchainTransactionStatus
    let rawPayload: Data?
    let effects: [WalletTransactionEffect]

    init(account: Account, transaction: BlockchainTransaction) throws {
        guard let accountId = account.id else { throw Error.invalidData }
        self.id = nil
        self.accountId = accountId
        chainIdentifier = try account.blockchain.asJSONString()
        let stableID = "\(accountId)|\(chainIdentifier)|\(transaction.identifier)"
        self.stableID = stableID
        blockHeight = transaction.blockHeight
        blockHash = transaction.blockHash
        timestamp = transaction.timestamp
        transactionIndex = transaction.transactionIndex
        sender = transaction.sender
        recipient = transaction.recipient
        status = transaction.status
        rawPayload = transaction.rawPayload
        effects = transaction.effects.map { WalletTransactionEffect(transactionID: stableID, effect: $0) }
    }

    init(model: WalletTransactionModel) {
        id = model.id
        accountId = model.account.id
        stableID = model.stableID
        chainIdentifier = model.chainIdentifier
        blockHeight = model.blockHeight
        blockHash = model.blockHash
        timestamp = model.timestamp
        transactionIndex = model.transactionIndex
        sender = model.sender
        recipient = model.recipient
        status = BlockchainTransactionStatus(rawValue: model.status) ?? .unconfirmed
        rawPayload = model.rawPayload
        effects = model.effects.map(WalletTransactionEffect.init(model:))
    }
}

struct WalletTransactionEffect: Identifiable, Sendable {
    let id: PersistentIdentifier?
    let stableID: String
    let index: UInt64
    let kind: BlockchainTransactionEffect.Kind
    let assetIdentifier: String?
    let amount: String?
    let sender: String?
    let recipient: String?
    let rawPayload: Data?

    init(transactionID: String, effect: BlockchainTransactionEffect) {
        id = nil
        stableID = "\(transactionID)|\(effect.index)|\(effect.kind.rawValue)"
        index = effect.index
        kind = effect.kind
        assetIdentifier = effect.assetIdentifier
        amount = effect.amount
        sender = effect.from
        recipient = effect.to
        rawPayload = effect.rawPayload
    }

    init(model: WalletTransactionEffectModel) {
        id = model.id
        stableID = model.stableID
        index = model.effectIndex
        kind = BlockchainTransactionEffect.Kind(rawValue: model.kind) ?? .unknown
        assetIdentifier = model.assetIdentifier
        amount = model.amount
        sender = model.sender
        recipient = model.recipient
        rawPayload = model.rawPayload
    }
}

/// Durable, chain-opaque progress state for the two concurrent sync tracks.
struct WalletTransactionSyncState: Sendable {
    let accountId: PersistentIdentifier
    var initialBackfillHead: UInt64?
    var descendingCursor: Data?
    var ascendingCursor: Data?
    var currentHead: UInt64?
    var backfillComplete: Bool
    var historyBoundary: UInt64?
    var lastError: String?

    init(accountId: PersistentIdentifier) {
        self.accountId = accountId
        initialBackfillHead = nil
        descendingCursor = nil
        ascendingCursor = nil
        currentHead = nil
        backfillComplete = false
        historyBoundary = nil
        lastError = nil
    }

    init(model: WalletTransactionSyncStateModel) {
        accountId = model.account.id
        initialBackfillHead = model.initialBackfillHead
        descendingCursor = model.descendingCursor
        ascendingCursor = model.ascendingCursor
        currentHead = model.currentHead
        backfillComplete = model.backfillComplete
        historyBoundary = model.historyBoundary
        lastError = model.lastError
    }
}

@Model
final class WalletTransactionModel {
    @Attribute(.unique) var stableID: String
    var chainIdentifier: String
    var blockHeight: UInt64?
    var blockHash: String?
    var timestamp: Date?
    var transactionIndex: UInt64?
    var sender: String?
    var recipient: String?
    var status: String
    var rawPayload: Data?

    @Relationship(deleteRule: .noAction)
    var account: AccountModel

    @Relationship(deleteRule: .cascade, inverse: \WalletTransactionEffectModel.transaction)
    var effects: [WalletTransactionEffectModel]

    init(account: AccountModel, transaction: WalletTransaction) {
        stableID = transaction.stableID
        chainIdentifier = transaction.chainIdentifier
        blockHeight = transaction.blockHeight
        blockHash = transaction.blockHash
        timestamp = transaction.timestamp
        transactionIndex = transaction.transactionIndex
        sender = transaction.sender
        recipient = transaction.recipient
        status = transaction.status.rawValue
        rawPayload = transaction.rawPayload
        self.account = account
        effects = []
    }
}

@Model
final class WalletTransactionEffectModel {
    @Attribute(.unique) var stableID: String
    var effectIndex: UInt64
    var kind: String
    var assetIdentifier: String?
    var amount: String?
    var sender: String?
    var recipient: String?
    var rawPayload: Data?

    @Relationship(deleteRule: .noAction)
    var transaction: WalletTransactionModel

    init(transaction: WalletTransactionModel, effect: WalletTransactionEffect) {
        stableID = effect.stableID
        effectIndex = effect.index
        kind = effect.kind.rawValue
        assetIdentifier = effect.assetIdentifier
        amount = effect.amount
        sender = effect.sender
        recipient = effect.recipient
        rawPayload = effect.rawPayload
        self.transaction = transaction
    }
}

@Model
final class WalletTransactionSyncStateModel {
    @Attribute(.unique) var accountStableID: String
    var initialBackfillHead: UInt64?
    var descendingCursor: Data?
    var ascendingCursor: Data?
    var currentHead: UInt64?
    var backfillComplete: Bool
    var historyBoundary: UInt64?
    var lastError: String?

    @Relationship(deleteRule: .noAction)
    var account: AccountModel

    init(account: AccountModel, state: WalletTransactionSyncState) {
        accountStableID = "\(account.id)"
        initialBackfillHead = state.initialBackfillHead
        descendingCursor = state.descendingCursor
        ascendingCursor = state.ascendingCursor
        currentHead = state.currentHead
        backfillComplete = state.backfillComplete
        historyBoundary = state.historyBoundary
        lastError = state.lastError
        self.account = account
    }
}
