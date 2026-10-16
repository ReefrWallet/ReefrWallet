//
//  DatabaseService+Balance.swift
//  ReefrWallet
//
//  Created by Andrey Yurkevich on 18/09/2026.
//

import SwiftData
import WalletKit

extension DatabaseService {
    #if DEBUG
    /// Deletes all balances across every account, keeping the tokens themselves.
    func deleteAllBalances() throws {
        try modelContext.delete(model: BalanceModel.self)
        try modelContext.save()
    }
    #endif

    func fetchBalance(account: Account, tokenAddress: String?) throws -> Balance? {
        guard let accountId = account.id else {
            throw ReefrError.invalidData
        }

        return try modelContext
            .fetch(FetchDescriptor(
                predicate: #Predicate { $0.account.persistentModelID == accountId && $0.token.address == tokenAddress }
            ))
            .first
            .map(Balance.init(model:))
    }

    func fetchBalances(accountId: PersistentIdentifier) throws -> [Balance] {
        try modelContext
            .fetch(FetchDescriptor(predicate: #Predicate { $0.account.persistentModelID == accountId }))
            .map(Balance.init(model:))
    }

    @discardableResult
    func saveBalance(_ balance: Balance) throws -> PersistentIdentifier {
        guard let id = try saveBalances([balance]).first else {
            throw ReefrError.invalidData
        }

        return id
    }

    /// Upserts every balance in one write transaction: batch-fetches the accounts, tokens, and
    /// existing balance rows the batch touches once each, instead of a handful of individual
    /// fetches per balance.
    @discardableResult // swiftlint:disable:next function_body_length
    func saveBalances(_ balances: [Balance]) throws -> [PersistentIdentifier] {
        guard !balances.isEmpty else {
            return []
        }

        var accountIds: Set<PersistentIdentifier> = []
        var tokenAddressesByBlockchain: [String: Set<String?>] = [:]

        for balance in balances {
            guard let accountId = balance.account.id else {
                throw ReefrError.invalidData
            }

            accountIds.insert(accountId)

            let serializedBlockchain = try balance.account.blockchain.asJSONString()
            tokenAddressesByBlockchain[serializedBlockchain, default: []].insert(balance.token.address)
        }

        let accountIndex = try fetchAccountModelIndex(accountIds: accountIds)

        var tokenIndex: [TokenIndexKey: TokenModel] = [:]
        for (serializedBlockchain, addresses) in tokenAddressesByBlockchain {
            for (address, model) in try fetchTokenIndex(
                serializedBlockchain: serializedBlockchain,
                addresses: addresses
            ) {
                tokenIndex[TokenIndexKey(serializedBlockchain: serializedBlockchain, address: address)] = model
            }
        }

        var balanceById: [PersistentIdentifier: BalanceModel] = [:]
        var balanceByAccountToken: [BalanceIndexKey: BalanceModel] = [:]

        for model in try fetchExistingBalanceModels(accountIds: accountIds) {
            balanceById[model.persistentModelID] = model
            balanceByAccountToken[
                BalanceIndexKey(accountId: model.account.persistentModelID, tokenAddress: model.token.address)
            ] = model
        }

        var results: [BalanceModel] = []

        for balance in balances {
            guard let accountId = balance.account.id, let accountModel = accountIndex[accountId] else {
                throw ReefrError.notFound
            }

            let serializedBlockchain = try balance.account.blockchain.asJSONString()
            let tokenKey = TokenIndexKey(serializedBlockchain: serializedBlockchain, address: balance.token.address)
            // Always applies `balance.token`'s fields to the row (matching a single
            // `upsertTokenModel` call) — only the fetch that finds the row is batched above.
            let tokenModel = try upsertTokenModel(
                balance.token,
                serializedBlockchain: serializedBlockchain,
                existing: tokenIndex[tokenKey]
            )

            tokenIndex[tokenKey] = tokenModel

            let balanceModel: BalanceModel

            if let balanceId = balance.id {
                balanceModel = balanceById[balanceId]
                    ?? BalanceModel(account: accountModel, amount: balance.amount, token: tokenModel)
            } else {
                let key = BalanceIndexKey(accountId: accountId, tokenAddress: balance.token.address)
                balanceModel = balanceByAccountToken[key]
                    ?? BalanceModel(account: accountModel, amount: balance.amount, token: tokenModel)
            }

            balanceModel.account = accountModel
            balanceModel.amount = balance.amount
            balanceModel.token = tokenModel

            if balanceModel.modelContext == nil {
                modelContext.insert(balanceModel)
            }

            balanceByAccountToken[
                BalanceIndexKey(accountId: accountId, tokenAddress: balance.token.address)
            ] = balanceModel
            results.append(balanceModel)
        }

        // IDs are read only after save() — a freshly-inserted model's `persistentModelID` is
        // temporary until the context commits it, and callers expect a permanent one back.
        try modelContext.save()
        return results.map(\.persistentModelID)
    }

    func updateBalances(account: Account, updates: [Balance]) throws {
        guard let accountId = account.id else {
            throw ReefrError.invalidData
        }

        guard let account = try fetchAccount(id: accountId) else {
            throw ReefrError.notFound
        }

        var balances = try fetchBalances(accountId: accountId)
        var tokens = try fetchTokens(blockchain: account.blockchain)

        for update in updates {
            let token: Token

            if var existing = tokens.first(where: { $0.address == update.token.address }) {
                existing.usdPrice = update.token.usdPrice ?? existing.usdPrice
                token = existing
            } else {
                // Not inserted here — `saveBalances` below creates the row as part of its
                // one batched save via `upsertTokenModel`, instead of paying for a separate
                // write transaction per newly-discovered token.
                tokens.append(update.token)
                token = update.token
            }

            if let index = balances.firstIndex(where: { $0.token.address == update.token.address }) {
                balances[index] = Balance(
                    account: account,
                    amount: update.amount,
                    token: token,
                    usdValue: update.usdValue
                )
            } else {
                balances.append(Balance(
                    account: account,
                    amount: update.amount,
                    token: token,
                    usdValue: update.usdValue
                ))
            }
        }

        try saveBalances(balances)
    }
}

private struct BalanceIndexKey: Hashable {
    let accountId: PersistentIdentifier
    let tokenAddress: String?
}

private struct TokenIndexKey: Hashable {
    let serializedBlockchain: String
    let address: String?
}

private extension DatabaseService {
    func fetchAccountModelIndex(accountIds: Set<PersistentIdentifier>) throws -> [PersistentIdentifier: AccountModel] {
        guard !accountIds.isEmpty else {
            return [:]
        }

        let predicate = #Predicate<AccountModel> { accountIds.contains($0.persistentModelID) }

        let models = try modelContext.fetch(FetchDescriptor(predicate: predicate))
        return Dictionary(models.map { ($0.persistentModelID, $0) }, uniquingKeysWith: { first, _ in first })
    }

    func fetchExistingBalanceModels(accountIds: Set<PersistentIdentifier>) throws -> [BalanceModel] {
        guard !accountIds.isEmpty else {
            return []
        }

        let predicate = #Predicate<BalanceModel> { accountIds.contains($0.account.persistentModelID) }

        return try modelContext.fetch(FetchDescriptor(predicate: predicate))
    }
}
