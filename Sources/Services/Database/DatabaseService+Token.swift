//
//  DatabaseService+Token.swift
//  ReefrWallet
//
//  Created by Andrey Yurkevich on 18/09/2026.
//

import SwiftData
import WalletKit

extension DatabaseService {
    #if DEBUG
    /// Deletes all non-native tokens on every blockchain, keeping each blockchain's mandatory
    /// native token intact. This respectively deletes all balances from all accounts.
    func deleteAllTokens() throws {
        try modelContext.delete(model: BalanceModel.self)
        try modelContext.delete(model: TokenSourceStatusModel.self)
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
            throw ReefrError.invalidData
        }

        let predicate = #Predicate<AccountModel> { $0.persistentModelID == accountId }

        guard let accountModel = try modelContext.fetch(FetchDescriptor(predicate: predicate)).first else {
            throw ReefrError.notFound
        }

        var transfers = tokenTransferEffects(accountId: accountId)
        transfers.propertiesToFetch = [\.assetIdentifier]
        let transferAddresses = try modelContext.fetch(transfers).compactMap(\.assetIdentifier)
        let tokenAddresses = Set(accountModel.balances.compactMap(\.token.address)).union(transferAddresses)

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

    /// Fetches the token matching `token.address` on `blockchain`, updating its descriptive fields
    /// in place, or creates one. Price, CoinGecko id, image and whitelisting of an existing row are
    /// left alone, since a stale snapshot would overwrite newer values. The lookup and write happen
    /// within a single non-suspending actor call, so this is safe to call from concurrent sync tracks that raced to discover the same token:
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
            // Price, identity and image start from the snapshot, then belong to their own writers.
            tokenModel.imageURL = token.imageURL
            tokenModel.isWhitelisted = token.isWhitelisted ? true : nil
            tokenModel.usdPrice = token.usdPrice
            modelContext.insert(tokenModel)
        }

        tokenModel.decimalsCount = token.decimalsCount
        tokenModel.isIncludedInBalance = token.isIncludedInBalance
        tokenModel.isNativeToken = token.isNativeToken
        tokenModel.name = token.name
        tokenModel.symbol = token.symbol

        return tokenModel
    }

    @discardableResult
    func insertToken(_ token: Token, blockchain: Blockchain) throws -> PersistentIdentifier {
        let serializedBlockchain = try blockchain.asJSONString()
        let tokenModel = try upsertTokenModel(token, serializedBlockchain: serializedBlockchain)
        try modelContext.save()
        return tokenModel.persistentModelID
    }

    /// Returns account-relevant tokens whose price is due, oldest (or never fetched) first: native
    /// tokens of chains with accounts, plus tokens some account holds. A token whose last fetch
    /// failed is due after `failureRetryInterval` instead of `refreshInterval`.
    func fetchTokensDueForPriceUpdate(
        now: Date,
        refreshInterval: TimeInterval,
        failureRetryInterval: TimeInterval,
        limit: Int
    ) throws -> [TokenPriceRequest] {
        let accounts = try modelContext.fetch(FetchDescriptor<AccountModel>())
        let accountBlockchains = Set(accounts.map(\.blockchain.serialized))

        guard !accountBlockchains.isEmpty else {
            return []
        }

        // An account's RPC override wins over the chain default, as in balance sync.
        let rpcURLOverrides = Dictionary(
            accounts.compactMap { account in
                account.rpcURLOverride.flatMap(URL.init(string:)).map { (account.blockchain.serialized, $0) }
            },
            uniquingKeysWith: { first, _ in first }
        )

        return try modelContext.fetch(FetchDescriptor<TokenModel>())
            .filter { token in
                guard let serialized = token.blockchain?.serialized,
                      accountBlockchains.contains(serialized) else {
                    return false
                }

                guard token.isNativeToken || token.isWhitelisted == true else {
                    return false
                }

                guard token.isNativeToken || (token.balances ?? []).contains(where: { $0.amount > 0 }) else {
                    return false
                }

                guard let priceUpdatedAt = token.priceUpdatedAt else {
                    return true
                }

                let interval = token.hasPriceFetchError ? failureRetryInterval : refreshInterval
                return now.timeIntervalSince(priceUpdatedAt) >= interval
            }
            .sorted { ($0.priceUpdatedAt ?? .distantPast) < ($1.priceUpdatedAt ?? .distantPast) }
            .prefix(limit)
            .compactMap { model in
                let token = Token(model: model)

                guard let blockchain = token.blockchain, let serialized = model.blockchain?.serialized else {
                    return nil
                }

                return TokenPriceRequest(
                    rpcURL: rpcURLOverrides[serialized] ?? blockchain.rpcURL,
                    token: token
                )
            }
    }

    /// Stamps `token` as fetched at `date` with a failed fetch, keeping its last good price but
    /// forgetting its source, so the next fetch tries sources in registry order.
    func markTokenPriceFetchFailed(_ token: Token, at date: Date) throws {
        let tokenModel = try tokenModel(for: token)
        tokenModel.hasPriceFetchError = true
        tokenModel.priceSourceId = nil
        tokenModel.priceUpdatedAt = date
        try modelContext.save()
    }

    func updateTokenPrices(_ tokens: [Token]) throws {
        for token in tokens {
            try updateTokenPrice(token, shouldSaveContext: false)
        }

        try modelContext.save()
    }
}

/// A token due for a price fetch, with the RPC endpoint its on-chain sources should use.
struct TokenPriceRequest: Sendable {
    let rpcURL: URL
    let token: Token
}

extension DatabaseService {
    func tokenModel(for token: Token) throws -> TokenModel {
        guard let blockchain = token.blockchain else {
            throw ReefrError.invalidData
        }

        let serializedBlockchain = try blockchain.asJSONString()
        let tokenAddress = token.address
        let predicate = #Predicate<TokenModel> {
            $0.blockchain?.serialized == serializedBlockchain && $0.address == tokenAddress
        }

        guard let tokenModel = try modelContext.fetch(FetchDescriptor(predicate: predicate)).first else {
            throw ReefrError.notFound
        }

        return tokenModel
    }

    /// Stores a successful quote: price, its source, CoinGecko id, and a fresh, error-free timestamp.
    @discardableResult
    func updateTokenPrice(_ token: Token, shouldSaveContext: Bool) throws -> PersistentIdentifier {
        let tokenModel = try tokenModel(for: token)
        tokenModel.coinGeckoId = token.coinGeckoId ?? tokenModel.coinGeckoId
        tokenModel.hasPriceFetchError = false
        tokenModel.priceSourceId = token.priceSourceId
        tokenModel.priceUpdatedAt = .now
        tokenModel.usdPrice = token.usdPrice

        if shouldSaveContext {
            try modelContext.save()
        }

        return tokenModel.persistentModelID
    }
}
