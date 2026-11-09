//
//  DatabaseService+Balance.swift
//  ReefrWallet
//
//  Created by Andrey Yurkevich on 18/09/2026.
//

import SwiftData
import WalletKit

struct BalanceListIndex: Equatable, Sendable {
    let hidden: [PersistentIdentifier]
    let native: Balance?
    let totalUSDValue: Decimal
    let visible: [PersistentIdentifier]
}

struct BalanceListSort: Hashable, Sendable {
    enum Field: Hashable, Sendable {
        case amount
        case name
        case price
        case value
    }

    let field: Field
    let ascending: Bool
}

private struct BalanceListRank {
    let id: PersistentIdentifier
    let amount: Decimal
    let isHidden: Bool
    let name: String
    let price: Decimal
    let value: Decimal

    func precedes(_ other: Self, sort: [BalanceListSort]) -> Bool {
        for order in sort {
            let result = switch order.field {
            case .amount: compare(amount, other.amount)
            case .name: name.localizedStandardCompare(other.name)
            case .price: compare(price, other.price)
            case .value: compare(value, other.value)
            }

            if result != .orderedSame {
                return result == (order.ascending ? .orderedAscending : .orderedDescending)
            }
        }

        return id < other.id
    }

    private func compare(_ lhs: Decimal, _ rhs: Decimal) -> ComparisonResult {
        if lhs < rhs {
            return .orderedAscending
        }

        return rhs < lhs ? .orderedDescending : .orderedSame
    }
}

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
        var descriptor = FetchDescriptor<BalanceModel>(
            predicate: #Predicate { $0.account.persistentModelID == accountId }
        )

        descriptor.relationshipKeyPathsForPrefetching = [\.token]
        return try modelContext.fetch(descriptor).map(Balance.init(model:))
    }

    func balanceListIndex(
        for account: Account,
        sort: [BalanceListSort],
        separatesHidden: Bool
    ) throws -> BalanceListIndex {
        guard let accountId = account.id else {
            throw ReefrError.invalidData
        }

        var descriptor = FetchDescriptor<BalanceModel>(
            predicate: #Predicate { $0.account.persistentModelID == accountId }
        )

        descriptor.relationshipKeyPathsForPrefetching = [\.token]
        var native: Balance?
        var total: Decimal = 0
        var ranks: [BalanceListRank] = []
        try modelContext.enumerate(descriptor, batchSize: 128) { model in
            try Task.checkCancellation()
            let token = model.token
            let amount = model.decimalAmount
            let price = token.usdPrice ?? 0
            let value = amount * price
            let hidden = token.isHidden
            if token.isNativeToken, native == nil {
                native = Balance(model: model, account: account)
            }

            if !hidden {
                total += value
            }

            ranks.append(BalanceListRank(
                id: model.persistentModelID,
                amount: amount,
                isHidden: hidden,
                name: token.name,
                price: price,
                value: value
            ))
        }

        ranks.sort { $0.precedes($1, sort: sort) }
        return BalanceListIndex(
            hidden: separatesHidden ? ranks.filter(\.isHidden).map(\.id) : [],
            native: native,
            totalUSDValue: total,
            visible: ranks.filter { !separatesHidden || !$0.isHidden }.map(\.id)
        )
    }

    func fetchBalancePage(
        for account: Account,
        orderedIds: [PersistentIdentifier],
        offset: Int,
        limit: Int
    ) throws -> AccountPage<Balance> {
        guard let accountId = account.id else {
            throw ReefrError.invalidData
        }

        let pageIds = orderedIds.dropFirst(offset).prefix(limit)
        guard !pageIds.isEmpty else {
            return AccountPage(rows: [], hasMore: false)
        }

        let ids = Set(pageIds)
        var descriptor = FetchDescriptor<BalanceModel>(
            predicate: #Predicate { ids.contains($0.persistentModelID) && $0.account.persistentModelID == accountId }
        )

        descriptor.relationshipKeyPathsForPrefetching = [\.token]
        let balances = try modelContext.fetch(descriptor).map {
            ($0.persistentModelID, Balance(model: $0, account: account))
        }

        let byId = Dictionary(uniqueKeysWithValues: balances)
        return AccountPage(rows: pageIds.compactMap { byId[$0] }, hasMore: offset + pageIds.count < orderedIds.count)
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
            // Applies the same updates as a single `upsertTokenModel` call — only the fetch that
            // finds the row is batched above.
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

            if let existing = tokens.first(where: { $0.address == update.token.address }) {
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
