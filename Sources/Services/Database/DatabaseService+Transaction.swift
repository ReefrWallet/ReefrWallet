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
            predicate: #Predicate { $0.account.id == accountId },
            sortBy: [
                SortDescriptor(\WalletTransactionModel.timestamp, order: .reverse),
                SortDescriptor(\WalletTransactionModel.transactionIndex, order: .reverse)
            ]
        )
        return try modelContext.fetch(descriptor).map(WalletTransaction.init(model:))
    }

    func transactionSyncState(accountId: PersistentIdentifier) throws -> WalletTransactionSyncState {
        let predicate = #Predicate<AccountModel> { $0.id == accountId }
        guard let account = try modelContext.fetch(FetchDescriptor(predicate: predicate)).first else {
            throw Error.notFound
        }

        if let state = account.transactionSyncState {
            return WalletTransactionSyncState(model: state)
        }

        return WalletTransactionSyncState(accountId: accountId)
    }

    func saveTransactions(_ transactions: [BlockchainTransaction], for account: Account) throws {
        guard let accountId = account.id else { throw Error.invalidData }
        let accountPredicate = #Predicate<AccountModel> { $0.id == accountId }
        guard let accountModel = try modelContext.fetch(FetchDescriptor(predicate: accountPredicate)).first else {
            throw Error.notFound
        }

        for chainTransaction in transactions {
            let transaction = try WalletTransaction(account: account, transaction: chainTransaction)
            let transactionStableID = transaction.stableID
            let transactionPredicate = #Predicate<WalletTransactionModel> { $0.stableID == transactionStableID }
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
                let effectStableID = effect.stableID
                let effectPredicate = #Predicate<WalletTransactionEffectModel> { $0.stableID == effectStableID }
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
            }
        }

        try modelContext.save()
    }

    func saveTransactionSyncState(_ state: WalletTransactionSyncState) throws {
        let accountID = state.accountId
        let predicate = #Predicate<AccountModel> { $0.id == accountID }
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
}
