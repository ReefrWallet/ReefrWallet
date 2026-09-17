//
//  DatabaseService+Balance.swift
//  ReefrWallet
//
//  Created by Andrey Yurkevich on 18/09/2026.
//

import Foundation
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

    func fetchBalance(account: Account, token: Token) throws -> Balance? {
        guard let accountId = account.id else {
            throw Error.invalidData
        }

        let tokenAddress = token.address

        return try modelContext
            .fetch(FetchDescriptor(
                predicate: #Predicate { $0.account.id == accountId && $0.token.address == tokenAddress }
            ))
            .first
            .map(Balance.init(model:))
    }

    func fetchBalances(accountId: PersistentIdentifier) throws -> [Balance] {
        try modelContext
            .fetch(FetchDescriptor(predicate: #Predicate { $0.account.id == accountId }))
            .map(Balance.init(model:))
    }

    @discardableResult
    func saveBalance(_ balance: Balance) throws -> PersistentIdentifier {
        try saveBalance(balance, shouldSaveContext: true)
    }

    func saveBalances(_ balances: [Balance]) throws {
        for balance in balances {
            try saveBalance(balance, shouldSaveContext: false)
        }

        try modelContext.save()
    }

    func updateBalances(account: Account, updates: [Balance]) throws {
        guard let accountId = account.id else {
            throw Error.invalidData
        }

        guard let account = try fetchAccount(id: accountId) else {
            throw Error.notFound
        }

        var balances = try fetchBalances(accountId: accountId)
        var tokens = try fetchTokens(blockchain: account.blockchain)

        for update in updates {
            let token: Token

            if var existing = tokens.first(where: { $0.address == update.token.address }) {
                existing.usdPrice = update.token.usdPrice ?? existing.usdPrice
                token = existing
            } else {
                try insertToken(update.token, blockchain: account.blockchain)
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

private extension DatabaseService {
    @discardableResult
    func saveBalance(_ balance: Balance, shouldSaveContext: Bool) throws -> PersistentIdentifier {
        guard let accountId = balance.account.id else {
            throw Error.invalidData
        }

        let accountPredicate = #Predicate<AccountModel> { $0.id == accountId }
        guard let accountModel = try modelContext.fetch(FetchDescriptor(predicate: accountPredicate)).first else {
            throw Error.notFound
        }

        let serializedBlockchain = try balance.account.blockchain.asJSONString()
        let tokenAddress = balance.token.address
        let tokenPredicate = #Predicate<TokenModel> {
            $0.blockchain?.serialized == serializedBlockchain && $0.address == tokenAddress
        }

        guard let tokenModel = try modelContext.fetch(FetchDescriptor(predicate: tokenPredicate)).first else {
            throw Error.notFound
        }

        tokenModel.decimalsCount = balance.token.decimalsCount
        tokenModel.imageURL = balance.token.imageURL
        tokenModel.isIncludedInBalance = balance.token.isIncludedInBalance
        tokenModel.isNativeToken = balance.token.isNativeToken
        tokenModel.name = balance.token.name
        tokenModel.symbol = balance.token.symbol
        tokenModel.usdPrice = balance.token.usdPrice

        let balanceModel: BalanceModel

        if let balanceId = balance.id {
            let balancePredicate = #Predicate<BalanceModel> { $0.id == balanceId }
            balanceModel = try modelContext.fetch(FetchDescriptor(predicate: balancePredicate)).first
                ?? BalanceModel(account: accountModel, amount: balance.amount, token: tokenModel)
        } else {
            let balancePredicate = #Predicate<BalanceModel> {
                $0.account.id == accountId && $0.token.address == tokenAddress
            }
            balanceModel = try modelContext.fetch(FetchDescriptor(predicate: balancePredicate)).first
                ?? BalanceModel(account: accountModel, amount: balance.amount, token: tokenModel)
        }

        balanceModel.account = accountModel
        balanceModel.amount = balance.amount
        balanceModel.token = tokenModel

        if balanceModel.modelContext == nil {
            modelContext.insert(balanceModel)
        }

        if shouldSaveContext {
            try modelContext.save()
        }

        return balanceModel.persistentModelID
    }
}
