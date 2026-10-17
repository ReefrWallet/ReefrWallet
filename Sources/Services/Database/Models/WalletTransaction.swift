//
//  WalletTransaction.swift
//  Reefr Wallet
//

import SwiftData
import WalletKit

/// App-level representation of a transaction stored for one wallet account.
/// The chain payload stays opaque so adding a blockchain never requires a
/// migration just to preserve a new chain-specific field.
struct WalletTransaction: Identifiable, Sendable {
    let id: PersistentIdentifier?
    let accountId: PersistentIdentifier
    let stableId: String
    let chainIdentifier: String
    let blockHeight: UInt64?
    let blockHash: String?
    let identifier: String
    let timestamp: Date?
    let transactionIndex: UInt64?
    let sender: String?
    let recipient: String?
    let status: BlockchainTransactionStatus
    let rawPayload: Data?
    let effects: [WalletTransactionEffect]
    let counterpartyName: String?
    let fee: String?
    let method: String?

    init(account: Account, transaction: BlockchainTransaction) throws {
        guard let accountId = account.id else {
            throw ReefrError.invalidData
        }

        self.id = nil
        self.accountId = accountId
        chainIdentifier = try account.blockchain.asJSONString()
        let stableId = try Self.stableId(
            accountId: accountId,
            chainIdentifier: chainIdentifier,
            identifier: transaction.identifier
        )

        self.stableId = stableId
        blockHeight = transaction.blockHeight
        blockHash = transaction.blockHash
        identifier = transaction.identifier
        timestamp = transaction.timestamp
        transactionIndex = transaction.transactionIndex
        sender = transaction.sender
        recipient = transaction.recipient
        status = transaction.status
        rawPayload = transaction.rawPayload
        effects = transaction.effects.map { WalletTransactionEffect(transactionId: stableId, effect: $0) }
        counterpartyName = transaction.counterpartyName
        fee = transaction.fee
        method = transaction.method
    }

    init(model: WalletTransactionModel) throws {
        id = model.id
        accountId = model.account.id
        stableId = model.stableId
        chainIdentifier = model.chainIdentifier
        blockHeight = model.blockHeight
        blockHash = model.blockHash
        identifier = model.identifier
        timestamp = model.timestamp
        transactionIndex = model.transactionIndex
        sender = model.sender
        recipient = model.recipient
        status = BlockchainTransactionStatus(rawValue: model.status) ?? .unconfirmed
        rawPayload = model.rawPayload
        effects = try model.effects.map(WalletTransactionEffect.init(model:))
        counterpartyName = model.counterpartyName
        fee = model.fee
        method = model.method
    }

    static func stableId(
        accountId: PersistentIdentifier,
        chainIdentifier: String,
        identifier: String
    ) throws -> String {
        "\(try accountId.stableKey())|\(chainIdentifier)|\(identifier)"
    }
}

extension PersistentIdentifier {
    private struct Encoded: Decodable {
        struct Implementation: Decodable {
            let uriRepresentation: String
        }

        let implementation: Implementation
    }

    /// The store URI (`x-coredata://<store>/<Entity>/p<N>`). Unlike `description`, which
    /// embeds a per-load object address, it's the same across launches and contexts.
    func stableKey() throws -> String {
        try JSONDecoder().decode(Encoded.self, from: JSONEncoder().encode(self)).implementation.uriRepresentation
    }
}

@Model
final class WalletTransactionModel {
    @Attribute(.unique) var stableId: String
    var chainIdentifier: String
    var blockHeight: UInt64?
    var blockHash: String?
    var identifier: String
    var timestamp: Date?
    var transactionIndex: UInt64?
    var sender: String?
    var recipient: String?
    var status: String
    var rawPayload: Data?
    var counterpartyName: String?
    var fee: String?
    var method: String?

    @Relationship(deleteRule: .noAction)
    var account: AccountModel

    @Relationship(deleteRule: .cascade, inverse: \WalletTransactionEffectModel.transaction)
    var effects: [WalletTransactionEffectModel]

    init(account: AccountModel, transaction: WalletTransaction) {
        stableId = transaction.stableId
        chainIdentifier = transaction.chainIdentifier
        blockHeight = transaction.blockHeight
        blockHash = transaction.blockHash
        identifier = transaction.identifier
        timestamp = transaction.timestamp
        transactionIndex = transaction.transactionIndex
        sender = transaction.sender
        recipient = transaction.recipient
        status = transaction.status.rawValue
        rawPayload = transaction.rawPayload
        counterpartyName = transaction.counterpartyName
        fee = transaction.fee
        method = transaction.method
        self.account = account
        effects = []
    }
}
