//
//  WalletTransactionEffect.swift
//  Reefr Wallet
//

import Foundation
import SwiftData
import WalletKit

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
