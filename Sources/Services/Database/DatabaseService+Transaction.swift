//
//  DatabaseService+Transaction.swift
//  ReefrWallet
//
//  Created by Andrey Yurkevich on 18/09/2026.
//

import Foundation
import SwiftData
import WalletKit

extension DatabaseService {
    func fetchTransactions(accountId: PersistentIdentifier) throws -> [WalletTransaction] {
        let descriptor = FetchDescriptor<WalletTransactionModel>(
            predicate: #Predicate { $0.account.persistentModelID == accountId },
            sortBy: [
                SortDescriptor(\WalletTransactionModel.timestamp, order: .reverse),
                SortDescriptor(\WalletTransactionModel.transactionIndex, order: .reverse)
            ]
        )

        return try modelContext.fetch(descriptor).map(WalletTransaction.init(model:))
    }

    func transactionSyncState(accountId: PersistentIdentifier) throws -> WalletTransactionSyncState {
        let predicate = #Predicate<AccountModel> { $0.persistentModelID == accountId }
        guard let account = try modelContext.fetch(FetchDescriptor(predicate: predicate)).first else {
            throw Error.notFound
        }

        if let state = account.transactionSyncState {
            return WalletTransactionSyncState(model: state)
        }

        return WalletTransactionSyncState(accountId: accountId)
    }

    func saveTransactions( // swiftlint:disable:this function_body_length
        _ transactions: [BlockchainTransaction],
        for account: Account
    ) throws {
        guard let accountId = account.id else {
            throw Error.invalidData
        }

        let accountPredicate = #Predicate<AccountModel> { $0.persistentModelID == accountId }

        guard let accountModel = try modelContext.fetch(FetchDescriptor(predicate: accountPredicate)).first else {
            throw Error.notFound
        }

        for chainTransaction in transactions {
            let transaction = try WalletTransaction(account: account, transaction: chainTransaction)
            let transactionStableId = transaction.stableId
            let transactionPredicate = #Predicate<WalletTransactionModel> { $0.stableId == transactionStableId }
            let model = try modelContext.fetch(FetchDescriptor(predicate: transactionPredicate)).first
                ?? WalletTransactionModel(account: accountModel, transaction: transaction)

            model.blockHeight = transaction.blockHeight
            model.blockHash = transaction.blockHash
            model.timestamp = transaction.timestamp
            model.transactionIndex = transaction.transactionIndex
            model.sender = transaction.sender
            model.recipient = transaction.recipient
            model.status = transaction.status.rawValue
            model.rawPayload = transaction.rawPayload

            if model.modelContext == nil {
                modelContext.insert(model)
            }

            for effect in transaction.effects {
                let effectStableId = effect.stableId
                let effectPredicate = #Predicate<WalletTransactionEffectModel> { $0.stableId == effectStableId }
                let effectModel = try modelContext.fetch(FetchDescriptor(predicate: effectPredicate)).first
                    ?? WalletTransactionEffectModel(transaction: model, effect: effect)
                effectModel.effectIndex = effect.index
                effectModel.kind = effect.kind.rawValue
                effectModel.assetIdentifier = effect.assetIdentifier
                effectModel.amount = effect.amount
                effectModel.sender = effect.sender
                effectModel.recipient = effect.recipient
                effectModel.rawPayload = effect.rawPayload
                effectModel.transaction = model

                if effectModel.modelContext == nil {
                    modelContext.insert(effectModel)
                }

                if effect.kind == .tokenTransfer, let tokenAddress = effect.assetIdentifier {
                    try linkBalance(
                        to: effectModel,
                        tokenAddress: tokenAddress,
                        account: accountModel,
                        blockchain: account.blockchain
                    )
                }
            }
        }

        try modelContext.save()
    }

    func saveTransactionSyncState(_ state: WalletTransactionSyncState) throws {
        let accountID = state.accountId
        let predicate = #Predicate<AccountModel> { $0.persistentModelID == accountID }
        guard let account = try modelContext.fetch(FetchDescriptor(predicate: predicate)).first else {
            throw Error.notFound
        }

        let model: WalletTransactionSyncStateModel
        if let existing = account.transactionSyncState {
            model = existing
        } else {
            model = WalletTransactionSyncStateModel(account: account, state: state)
            account.transactionSyncState = model
            modelContext.insert(model)
        }

        model.initialBackfillHead = state.initialBackfillHead
        model.descendingCursor = state.descendingCursor
        model.ascendingCursor = state.ascendingCursor
        model.currentHead = state.currentHead
        model.backfillComplete = state.backfillComplete
        model.historyBoundary = state.historyBoundary
        model.lastError = state.lastError
        try modelContext.save()
    }

    func linkTransactionTokens(for account: Account) throws {
        guard let accountID = account.id else {
            throw Error.invalidData
        }

        let predicate = #Predicate<WalletTransactionModel> { $0.account.persistentModelID == accountID }
        let transactions = try modelContext.fetch(FetchDescriptor(predicate: predicate))

        for transaction in transactions {
            for effect in transaction.effects {
                guard effect.kind == BlockchainTransactionEffect.Kind.tokenTransfer.rawValue,
                      let tokenAddress = effect.assetIdentifier
                else {
                    continue
                }

                try linkBalance(
                    to: effect,
                    tokenAddress: tokenAddress,
                    account: transaction.account,
                    blockchain: account.blockchain
                )
            }
        }

        try modelContext.save()
    }
}

private extension DatabaseService {
    func linkBalance(
        to effect: WalletTransactionEffectModel,
        tokenAddress: String,
        account: AccountModel,
        blockchain: WKBlockchain
    ) throws {
        let serializedBlockchain = try blockchain.asJSONString()
        let accountId = account.persistentModelID
        let balancePredicate = #Predicate<BalanceModel> {
            $0.account.persistentModelID == accountId
            && $0.token.address == tokenAddress
            && $0.token.blockchain?.serialized == serializedBlockchain
        }

        guard let balance = try modelContext.fetch(FetchDescriptor(predicate: balancePredicate)).first else {
            return
        }

        effect.balance = balance
    }
}
