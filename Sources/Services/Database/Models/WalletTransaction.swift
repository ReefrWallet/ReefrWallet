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
