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

    func saveTransactions(
        _ transactions: [BlockchainTransaction],
        for account: Account
    ) throws {
        try saveTransactions(transactions, for: account, syncState: nil)
    }

    /// Upserts `transactions` and, when `syncState` is provided, the account's sync cursor —
    /// both in the same write transaction, so a backfill page costs one `save()` instead of two.
    func saveTransactions( // swiftlint:disable:this function_body_length
        _ transactions: [BlockchainTransaction],
        for account: Account,
        syncState: WalletTransactionSyncState?
    ) throws {
        guard let accountId = account.id else {
            throw Error.invalidData
        }

        let accountPredicate = #Predicate<AccountModel> { $0.persistentModelID == accountId }

        guard let accountModel = try modelContext.fetch(FetchDescriptor(predicate: accountPredicate)).first else {
            throw Error.notFound
        }

        let walletTransactions = try transactions.map { try WalletTransaction(account: account, transaction: $0) }

        var transactionIndex = try fetchTransactionIndex(stableIds: Set(walletTransactions.map(\.stableId)))
        var effectIndex = try fetchEffectIndex(
            stableIds: Set(walletTransactions.flatMap(\.effects).map(\.stableId))
        )
        let tokenAddresses = Set(
            walletTransactions
                .flatMap(\.effects)
                .filter { $0.kind == .tokenTransfer }
                .compactMap(\.assetIdentifier)
        )
        let balanceIndex = try fetchBalanceIndex(
            accountId: accountId,
            tokenAddresses: tokenAddresses,
            blockchain: account.blockchain
        )

        for transaction in walletTransactions {
            let model = transactionIndex[transaction.stableId]
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

            transactionIndex[transaction.stableId] = model

            for effect in transaction.effects {
                let effectModel = effectIndex[effect.stableId]
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

                effectIndex[effect.stableId] = effectModel

                if effect.kind == .tokenTransfer,
                   let tokenAddress = effect.assetIdentifier,
                   let balance = balanceIndex[tokenAddress] {
                    effectModel.balance = balance
                }
            }
        }

        if let syncState {
            applySyncState(syncState, to: accountModel)
        }

        try modelContext.save()
    }

    func saveTransactionSyncState(_ state: WalletTransactionSyncState) throws {
        let accountId = state.accountId
        let predicate = #Predicate<AccountModel> { $0.persistentModelID == accountId }
        guard let account = try modelContext.fetch(FetchDescriptor(predicate: predicate)).first else {
            throw Error.notFound
        }

        applySyncState(state, to: account)
        try modelContext.save()
    }

    func linkTransactionTokens(for account: Account) throws {
        guard let accountId = account.id else {
            throw Error.invalidData
        }

        let predicate = #Predicate<WalletTransactionModel> { $0.account.persistentModelID == accountId }
        let transactions = try modelContext.fetch(FetchDescriptor(predicate: predicate))

        let tokenAddresses = Set(
            transactions
                .flatMap(\.effects)
                .filter { $0.kind == BlockchainTransactionEffect.Kind.tokenTransfer.rawValue }
                .compactMap(\.assetIdentifier)
        )

        let balanceIndex = try fetchBalanceIndex(
            accountId: accountId,
            tokenAddresses: tokenAddresses,
            blockchain: account.blockchain
        )

        for transaction in transactions {
            for effect in transaction.effects {
                guard effect.kind == BlockchainTransactionEffect.Kind.tokenTransfer.rawValue,
                      let tokenAddress = effect.assetIdentifier,
                      let balance = balanceIndex[tokenAddress]
                else {
                    continue
                }

                effect.balance = balance
            }
        }

        try modelContext.save()
    }
}

private extension DatabaseService {
    func applySyncState(_ state: WalletTransactionSyncState, to account: AccountModel) {
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
    }

    func fetchBalanceIndex(
        accountId: PersistentIdentifier,
        tokenAddresses: Set<String>,
        blockchain: WKBlockchain
    ) throws -> [String: BalanceModel] {
        guard !tokenAddresses.isEmpty else {
            return [:]
        }

        let serializedBlockchain = try blockchain.asJSONString()
        let predicate = #Predicate<BalanceModel> { balance in
            if let address = balance.token.address {
                return balance.account.persistentModelID == accountId
                    && balance.token.blockchain?.serialized == serializedBlockchain
                    && tokenAddresses.contains(address)
            } else {
                return false
            }
        }

        let balances = try modelContext.fetch(FetchDescriptor(predicate: predicate))

        return Dictionary(
            balances.compactMap { balance in balance.token.address.map { ($0, balance) } },
            uniquingKeysWith: { first, _ in first }
        )
    }

    func fetchEffectIndex(stableIds: Set<String>) throws -> [String: WalletTransactionEffectModel] {
        guard !stableIds.isEmpty else {
            return [:]
        }

        let predicate = #Predicate<WalletTransactionEffectModel> { stableIds.contains($0.stableId) }
        let models = try modelContext.fetch(FetchDescriptor(predicate: predicate))
        return Dictionary(models.map { ($0.stableId, $0) }, uniquingKeysWith: { first, _ in first })
    }

    func fetchTransactionIndex(stableIds: Set<String>) throws -> [String: WalletTransactionModel] {
        guard !stableIds.isEmpty else {
            return [:]
        }

        let predicate = #Predicate<WalletTransactionModel> { stableIds.contains($0.stableId) }
        let models = try modelContext.fetch(FetchDescriptor(predicate: predicate))
        return Dictionary(models.map { ($0.stableId, $0) }, uniquingKeysWith: { first, _ in first })
    }
}
