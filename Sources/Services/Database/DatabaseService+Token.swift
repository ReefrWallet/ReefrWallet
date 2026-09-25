//
//  DatabaseService+Token.swift
//  ReefrWallet
//
//  Created by Andrey Yurkevich on 18/09/2026.
//

import Foundation
import SwiftData
import WalletKit

extension DatabaseService {
    #if DEBUG
    /// Deletes all non-native tokens on every blockchain, keeping each blockchain's mandatory
    /// native token intact. This respectively deletes all balances from all accounts.
    func deleteAllTokens() throws {
        try modelContext.delete(model: BalanceModel.self)
        try modelContext.delete(model: TokenModel.self, where: #Predicate { !$0.isNativeToken })
        try modelContext.save()
    }
    #endif

    func fetchToken(tokenAddress: String, blockchain: Blockchain) throws -> Token? {
        let serializedBlockchain = try blockchain.asJSONString()
        let predicate = #Predicate<TokenModel> { token in
            if let address = token.address {
                return token.blockchain?.serialized == serializedBlockchain
                && tokenAddress == address
            } else {
                return false
            }
        }

        return try modelContext.fetch(FetchDescriptor(predicate: predicate)).first.map(Token.init(model:))
    }

    /// Returns the native token plus assets this account has either held or
    /// transferred. Tokens discovered by other accounts on the same blockchain
    /// are intentionally excluded.
    func fetchTokens(account: Account) throws -> [Token] {
        guard let accountId = account.id else {
            throw Error.invalidData
        }

        let predicate = #Predicate<AccountModel> { $0.persistentModelID == accountId }

        guard let accountModel = try modelContext.fetch(FetchDescriptor(predicate: predicate)).first else {
            throw Error.notFound
        }

        let tokenAddresses = Set(accountModel.balances.compactMap(\.token.address)).union(
            accountModel.transactions
                .flatMap(\.effects)
                .filter { $0.kind == BlockchainTransactionEffect.Kind.tokenTransfer.rawValue }
                .compactMap(\.assetIdentifier)
        )

        return accountModel.blockchain.tokens
            .filter { $0.isNativeToken || tokenAddresses.contains($0.address ?? "") }
            .map(Token.init(model:))
    }

    func fetchTokens(blockchain: Blockchain) throws -> [Token] {
        let serializedBlockchain = try blockchain.asJSONString()
        return try modelContext
            .fetch(FetchDescriptor(predicate: #Predicate { $0.blockchain?.serialized == serializedBlockchain }))
            .map(Token.init(model:))
    }

    /// Batch-fetches every `TokenModel` in `addresses` (an entry of `nil` matches the chain's
    /// native token) on `blockchain`, in one query — used by `saveBalances` so a multi-balance
    /// batch doesn't look up its tokens one at a time.
    func fetchTokenIndex(serializedBlockchain: String, addresses: Set<String?>) throws -> [String?: TokenModel] {
        guard !addresses.isEmpty else {
            return [:]
        }

        let nonNilAddresses = Set(addresses.compactMap { $0 })
        let includesNativeToken = addresses.contains(nil)

        let predicate = #Predicate<TokenModel> { token in
            if let address = token.address {
                return token.blockchain?.serialized == serializedBlockchain && nonNilAddresses.contains(address)
            } else {
                return includesNativeToken && token.blockchain?.serialized == serializedBlockchain
            }
        }

        let models = try modelContext.fetch(FetchDescriptor(predicate: predicate))
        return Dictionary(models.map { ($0.address, $0) }, uniquingKeysWith: { first, _ in first })
    }

    /// Fetches the token matching `token.address` on `blockchain`, updating it in place, or
    /// creates one. The lookup and write happen within a single non-suspending actor call, so
    /// this is safe to call from concurrent sync tracks that raced to discover the same token:
    /// whichever call lands second finds and updates the row the first one created instead of
    /// inserting a duplicate.
    @discardableResult
    func upsertTokenModel(_ token: Token, serializedBlockchain: String) throws -> TokenModel {
        let tokenAddress = token.address
        let predicate = #Predicate<TokenModel> {
            $0.blockchain?.serialized == serializedBlockchain && $0.address == tokenAddress
        }

        let existing = try modelContext.fetch(FetchDescriptor(predicate: predicate)).first
        return try upsertTokenModel(token, serializedBlockchain: serializedBlockchain, existing: existing)
    }

    /// Same upsert as `upsertTokenModel(_:serializedBlockchain:)`, but takes an already-resolved
    /// row (e.g. from `fetchTokenIndex`) instead of running its own fetch — lets a batch caller
    /// skip one query per item while still applying the field updates to every row.
    @discardableResult
    func upsertTokenModel(
        _ token: Token,
        serializedBlockchain: String,
        existing: TokenModel?
    ) throws -> TokenModel {
        let tokenModel = existing ?? TokenModel(from: token)

        if tokenModel.modelContext == nil {
            tokenModel.blockchain = try modelContext
                .fetch(FetchDescriptor(
                    predicate: #Predicate<BlockchainModel> { $0.serialized == serializedBlockchain }
                ))
                .first
            modelContext.insert(tokenModel)
        }

        tokenModel.decimalsCount = token.decimalsCount
        tokenModel.imageURL = token.imageURL
        tokenModel.isIncludedInBalance = token.isIncludedInBalance
        tokenModel.isNativeToken = token.isNativeToken
        tokenModel.name = token.name
        tokenModel.symbol = token.symbol
        tokenModel.usdPrice = token.usdPrice

        return tokenModel
    }

    @discardableResult
    func insertToken(_ token: Token, blockchain: Blockchain) throws -> PersistentIdentifier {
        let serializedBlockchain = try blockchain.asJSONString()
        let tokenModel = try upsertTokenModel(token, serializedBlockchain: serializedBlockchain)
        try modelContext.save()
        return tokenModel.persistentModelID
    }

    func updateTokenPrices(_ tokens: [Token]) throws {
        for token in tokens {
            try updateTokenPrice(token, shouldSaveContext: false)
        }

        try modelContext.save()
    }
}

private extension DatabaseService {
    @discardableResult
    func updateTokenPrice(_ token: Token, shouldSaveContext: Bool) throws -> PersistentIdentifier {
        guard let blockchain = token.blockchain else {
            throw Error.invalidData
        }

        let serializedBlockchain = try blockchain.asJSONString()
        let tokenAddress = token.address
        let predicate = #Predicate<TokenModel> {
            $0.blockchain?.serialized == serializedBlockchain && $0.address == tokenAddress
        }

        guard let tokenModel = try modelContext.fetch(FetchDescriptor(predicate: predicate)).first else {
            throw Error.notFound
        }

        tokenModel.usdPrice = token.usdPrice

        if shouldSaveContext {
            try modelContext.save()
        }

        return tokenModel.persistentModelID
    }
}
