//
//  DatabaseService+Transaction.swift
//  ReefrWallet
//
//  Created by Andrey Yurkevich on 18/09/2026.
//

import SwiftData
import WalletKit

extension DatabaseService {
    #if DEBUG
    /// Deletes all persisted transaction history and sync cursors so the next
    /// synchronization performs a fresh backfill.
    func deleteAllTransactions() throws {
        let accounts = try modelContext.fetch(FetchDescriptor<AccountModel>())

        for account in accounts {
            for transaction in account.transactions {
                for effect in transaction.effects {
                    modelContext.delete(effect)
                }

                modelContext.delete(transaction)
            }

            if let syncState = account.transactionSyncState {
                account.transactionSyncState = nil
                modelContext.delete(syncState)
            }
        }

        try modelContext.save()
    }
    #endif

    /// Removes the placeholder a broadcast recorded for `identifier`, if it is still one.
    ///
    /// - Returns: whether one was removed; a confirmed or failed row is never touched.
    @discardableResult
    func removeBroadcastPlaceholder(identifier: String, for account: Account) throws -> Bool {
        let removed = try deleteBroadcastPlaceholder(identifier: identifier, for: account)

        if removed {
            try modelContext.save()
        }

        return removed
    }

    /// Like ``removeBroadcastPlaceholder(identifier:for:)``, but leaves saving to the caller so the removal
    /// can share one save with other changes.
    func deleteBroadcastPlaceholder(identifier: String, for account: Account) throws -> Bool {
        let placeholder = BlockchainTransaction(identifier: identifier, status: .broadcast)
        let stableId = try WalletTransaction(account: account, transaction: placeholder).stableId

        guard
            let model = try fetchTransactionIndex(stableIds: [stableId])[stableId],
            model.status == BlockchainTransactionStatus.broadcast.rawValue
        else {
            return false
        }

        for effect in model.effects {
            modelContext.delete(effect)
        }

        modelContext.delete(model)
        return true
    }

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

    /// The highest block height among the account's stored transactions.
    func latestTransactionBlockHeight(accountId: PersistentIdentifier) throws -> UInt64? {
        var descriptor = FetchDescriptor<WalletTransactionModel>(
            predicate: #Predicate { $0.account.persistentModelID == accountId && $0.blockHeight != nil },
            sortBy: [SortDescriptor(\.blockHeight, order: .reverse)]
        )

        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first?.blockHeight
    }

    func transactionSyncState(accountId: PersistentIdentifier) throws -> WalletTransactionSyncState {
        let predicate = #Predicate<AccountModel> { $0.persistentModelID == accountId }

        guard let account = try modelContext.fetch(FetchDescriptor(predicate: predicate)).first else {
            throw ReefrError.notFound
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
            throw ReefrError.invalidData
        }

        let accountPredicate = #Predicate<AccountModel> { $0.persistentModelID == accountId }

        guard let accountModel = try modelContext.fetch(FetchDescriptor(predicate: accountPredicate)).first else {
            throw ReefrError.notFound
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
            // Sources differ in richness (indexer vs. node); don't let a poorer re-sync erase labels.
            model.counterpartyName = transaction.counterpartyName ?? model.counterpartyName
            model.fee = transaction.fee ?? model.fee
            model.method = transaction.method ?? model.method

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
            throw ReefrError.notFound
        }

        applySyncState(state, to: account)
        try modelContext.save()
    }

    func linkTransactionTokens(for account: Account) throws {
        guard let accountId = account.id else {
            throw ReefrError.invalidData
        }

        let effects = try modelContext.fetch(tokenTransferEffects(accountId: accountId, onlyUnlinked: true))
        guard !effects.isEmpty else {
            return
        }

        let balanceIndex = try fetchBalanceIndex(
            accountId: accountId,
            tokenAddresses: Set(effects.compactMap(\.assetIdentifier)),
            blockchain: account.blockchain
        )

        // EVM contract addresses are case-insensitive; older effects store the
        // lowercase spelling while balances use the checksummed one.
        var caseInsensitiveIndex: [String: BalanceModel] = [:]

        if case .evm = account.blockchain {
            for balance in try fetchBalanceModels(accountId: accountId) {
                if let address = balance.token.address {
                    caseInsensitiveIndex[address.lowercased()] = balance
                }
            }
        }

        for effect in effects {
            guard let tokenAddress = effect.assetIdentifier,
                  let balance = balanceIndex[tokenAddress] ?? caseInsensitiveIndex[tokenAddress.lowercased()]
            else {
                continue
            }

            effect.balance = balance
        }

        if modelContext.hasChanges {
            try modelContext.save()
        }
    }

    func tokenTransferEffects(
        accountId: PersistentIdentifier,
        onlyUnlinked: Bool = false
    ) -> FetchDescriptor<WalletTransactionEffectModel> {
        let kind = BlockchainTransactionEffect.Kind.tokenTransfer.rawValue
        return FetchDescriptor(predicate: #Predicate {
            $0.transaction.account.persistentModelID == accountId
                && $0.kind == kind
                && $0.assetIdentifier != nil
                && (!onlyUnlinked || $0.balance == nil)
        })
    }

    /// Rewrites stable ids from the old `PersistentIdentifier.description` form, which changed
    /// per launch and duplicated rows on every rescan, and drops the duplicates. A no-op once done.
    func normalizeTransactionStableIds() throws {
        var groups: [String: [WalletTransactionModel]] = [:]

        for model in try modelContext.fetch(FetchDescriptor<WalletTransactionModel>()) {
            let stableId = try WalletTransaction.stableId(
                accountId: model.account.persistentModelID,
                chainIdentifier: model.chainIdentifier,
                identifier: model.identifier
            )

            groups[stableId, default: []].append(model)
        }

        let stale = groups.filter { stableId, models in models.count > 1 || models[0].stableId != stableId }

        guard !stale.isEmpty else {
            return
        }

        // Prefer the row with a block height (confirmed), so a stale "Pending" copy goes.
        var survivors: [String: WalletTransactionModel] = [:]

        for (stableId, models) in stale {
            let sorted = models.sorted { ($0.blockHeight != nil ? 0 : 1) < ($1.blockHeight != nil ? 0 : 1) }
            survivors[stableId] = sorted[0]
            sorted.dropFirst().forEach(modelContext.delete)
        }

        // Deletes first, so renamed rows can't collide with a unique id still being dropped.
        try modelContext.save()

        for (stableId, model) in survivors {
            model.stableId = stableId

            for effect in model.effects {
                effect.stableId = "\(stableId)|\(effect.effectIndex)|\(effect.kind)"
            }
        }

        try modelContext.save()
        printDebug("Normalized \(stale.count) transaction ids")
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
        blockchain: Blockchain
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

private extension DatabaseService {
    func fetchBalanceModels(accountId: PersistentIdentifier) throws -> [BalanceModel] {
        try modelContext.fetch(FetchDescriptor<BalanceModel>(
            predicate: #Predicate { $0.account.persistentModelID == accountId }
        ))
    }
}
