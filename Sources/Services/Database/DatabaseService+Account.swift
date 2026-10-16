//
//  DatabaseService+Account.swift
//  ReefrWallet
//
//  Created by Andrey Yurkevich on 18/09/2026.
//

import SwiftData
import WalletKit

extension DatabaseService {
    func deleteAccount(id: PersistentIdentifier) throws {
        let predicate = #Predicate<AccountModel> { $0.persistentModelID == id }

        guard let account = try modelContext.fetch(FetchDescriptor(predicate: predicate)).first else {
            throw ReefrError.notFound
        }

        modelContext.delete(account)
        try modelContext.save()
    }

    #if DEBUG
    /// Deletes all accounts across every key store, keeping the key stores themselves.
    func deleteAllAccounts() throws {
        try modelContext.delete(model: AccountModel.self)
        try modelContext.delete(model: BlockchainModel.self)
        try modelContext.save()
    }
    #endif

    func fetchAccount(id: PersistentIdentifier) throws -> Account? {
        try modelContext
            .fetch(FetchDescriptor(predicate: #Predicate<AccountModel> { $0.persistentModelID == id }))
            .first
            .map { try Account(model: $0) }
    }

    func fetchAccounts(
        keyStoreId: PersistentIdentifier,
        blockchain: Blockchain? = nil
    ) throws -> [Account] {
        let serializedBlockchain = try blockchain?.asJSONString()
        let predicate: Predicate<AccountModel>

        if let serializedBlockchain {
            predicate = #Predicate<AccountModel> {
                $0.keyStore.persistentModelID == keyStoreId && $0.blockchain.serialized == serializedBlockchain
            }
        } else {
            predicate = #Predicate<AccountModel> {
                $0.keyStore.persistentModelID == keyStoreId
            }
        }

        return try modelContext
            .fetch(FetchDescriptor(predicate: predicate))
            .map { try Account(model: $0) }
    }

    func fetchAllAccounts() throws -> [Account] {
        try modelContext.fetch(FetchDescriptor<AccountModel>()).map { try Account(model: $0) }
    }

    @discardableResult
    func insertAccount(_ account: Account, keyStore: KeyStore) throws -> PersistentIdentifier {
        guard let keyStoreId = keyStore.id else {
            throw ReefrError.invalidData
        }

        let keyStorePredicate = #Predicate<KeyStoreModel> { $0.persistentModelID == keyStoreId }

        guard let keyStore = try modelContext.fetch(FetchDescriptor(predicate: keyStorePredicate)).first else {
            throw ReefrError.notFound
        }

        let serializedBlockchain = try account.blockchain.asJSONString()
        var blockchain = try modelContext
            .fetch(FetchDescriptor(predicate: #Predicate<BlockchainModel> { $0.serialized == serializedBlockchain }))
            .first

        if blockchain == nil {
            blockchain = try BlockchainModel(blockchain: account.blockchain)
        }

        let model = try AccountModel(account: account, blockchain: blockchain!, keyStore: keyStore)
        modelContext.insert(model)
        try modelContext.save()

        return model.persistentModelID
    }

    func renameAccount(id: PersistentIdentifier, name: String) throws {
        let predicate = #Predicate<AccountModel> { $0.persistentModelID == id }

        guard let account = try modelContext.fetch(FetchDescriptor(predicate: predicate)).first else {
            throw ReefrError.notFound
        }

        account.name = name
        try modelContext.save()
    }

    func usdValue(accountId: PersistentIdentifier) throws -> Decimal {
        let predicate = #Predicate<AccountModel> { $0.persistentModelID == accountId }

        guard let accountModel = try modelContext.fetch(FetchDescriptor(predicate: predicate)).first else {
            throw ReefrError.notFound
        }

        return accountModel.usdValue()
    }
}
