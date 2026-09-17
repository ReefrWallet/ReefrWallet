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

    func fetchToken(tokenAddress: String, blockchain: WKBlockchain) throws -> Token? {
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

    func fetchTokens(account: Account) throws -> [Token] {
        guard let accountId = account.id else {
            throw Error.invalidData
        }

        let predicate = #Predicate<AccountModel> { $0.id == accountId }

        guard let accountModel = try modelContext.fetch(FetchDescriptor(predicate: predicate)).first else {
            throw Error.notFound
        }

        return accountModel.balances.map { Token(model: $0.token) }
    }

    func fetchTokens(blockchain: WKBlockchain) throws -> [Token] {
        let serializedBlockchain = try blockchain.asJSONString()
        return try modelContext
            .fetch(FetchDescriptor(predicate: #Predicate { $0.blockchain?.serialized == serializedBlockchain }))
            .map(Token.init(model:))
    }

    @discardableResult
    func insertToken(_ token: Token, blockchain: WKBlockchain) throws -> PersistentIdentifier {
        let serializedBlockchain = try blockchain.asJSONString()
        let blockchainModel = try modelContext
            .fetch(FetchDescriptor(predicate: #Predicate<BlockchainModel> { $0.serialized == serializedBlockchain }))
            .first

        let tokenModel = TokenModel(from: token)
        tokenModel.blockchain = blockchainModel
        tokenModel.imageURL = token.imageURL
        tokenModel.isIncludedInBalance = token.isIncludedInBalance
        tokenModel.usdPrice = token.usdPrice

        modelContext.insert(tokenModel)
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
