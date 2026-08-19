//
//  DatabaseService.swift
//  Reefr Wallet
//
//  Created by Andrey Yurkevich on 21.02.26.
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import Foundation
import SwiftData
import WalletKit

@ModelActor
actor DatabaseService {
    func deleteAccount(_ account: Account) throws {
        let accountId = account.id
        let predicate = #Predicate<Account> { $0.id == accountId }

        try modelContext.delete(model: Account.self, where: predicate)
        try modelContext.save()
    }

    func deleteKeyStore(_ keyStore: KeyStore) throws {
        let keyId = keyStore.id
        let predicate = #Predicate<KeyStore> { $0.id == keyId }

        try modelContext.delete(model: KeyStore.self, where: predicate)
        try modelContext.save()
    }

    func fetchAccount(id: PersistentIdentifier) throws -> Account {
        let predicate = #Predicate<Account> { $0.id == id }
        let descriptor = FetchDescriptor(predicate: predicate)

        guard let account = try modelContext.fetch(descriptor).first else {
            throw Error.notFound
        }

        return account
    }

    func fetchBlockchainConfig(_ blockchainConfig: BlockchainConfig) throws -> BlockchainConfig {
        let serializedBlockchain = try blockchainConfig.blockchain.asJSONString()
        let predicate = #Predicate<BlockchainConfig> { $0.serializedBlockchain == serializedBlockchain }
        let descriptor = FetchDescriptor(predicate: predicate)

        if let config = try modelContext.fetch(descriptor).first {
            return config
        }

        try saveBlockchainConfig(blockchainConfig)
        guard let config = try modelContext.fetch(descriptor).first else {
            throw Error.notFound
        }

        return config
    }

    func fetchBlockchains() throws -> [BlockchainConfig] {
        let predicate = #Predicate<BlockchainConfig> { !$0.isTestnet && $0.presetId != nil }
        let descriptor = FetchDescriptor(predicate: predicate)
        return try modelContext.fetch(descriptor)
    }

    func fetchKeyStore(id: PersistentIdentifier) throws -> KeyStore {
        let predicate = #Predicate<KeyStore> { $0.id == id }
        let descriptor = FetchDescriptor(predicate: predicate)

        guard let keyStore = try modelContext.fetch(descriptor).first else {
            throw Error.notFound
        }

        return keyStore
    }

    func fetchToken(_ address: String, blockchain: Blockchain) async throws -> Token? {
        let serializedBlockchain = try blockchain.asJSONString()
        let blockchainPredicate = #Predicate<Token> { $0.blockchain?.serializedBlockchain == serializedBlockchain }
        let addressPredicate = #Predicate<Token> { $0.address == address }

        let predicate = #Predicate<Token> {
            blockchainPredicate.evaluate($0) && addressPredicate.evaluate($0)
        }

        let fetchDescriptor = FetchDescriptor(predicate: predicate)
        return try modelContext.fetch(fetchDescriptor).first
    }

    func fetchToken(id: PersistentIdentifier) async throws -> Token {
        let predicate = #Predicate<Token> { $0.id == id }
        let fetchDescriptor = FetchDescriptor(predicate: predicate)

        guard let token = try modelContext.fetch(fetchDescriptor).first else {
            throw Error.notFound
        }

        return token
    }

    func fetchTokens() async throws -> [Token] {
        let fetchDescriptor = FetchDescriptor<Token>()
        return try modelContext.fetch(fetchDescriptor)
    }

    func fetchTokens(symbol: String) async throws -> [Token] {
        let predicate = #Predicate<Token> { $0.symbol == symbol }
        let fetchDescriptor = FetchDescriptor(predicate: predicate)
        return try modelContext.fetch(fetchDescriptor)
    }

    func fetchTrezorKeyStore(_ deviceId: String) throws -> KeyStore? {
        let predicate = #Predicate<KeyStore> { $0.deviceId == deviceId }
        let descriptor = FetchDescriptor(predicate: predicate)
        return try modelContext.fetch(descriptor).first
    }

    func saveAccount(_ account: Account) throws {
        modelContext.insert(account)
        try modelContext.save()
    }

    func saveBlockchainConfig(_ blockchainConfig: BlockchainConfig) throws {
        modelContext.insert(blockchainConfig)
        try modelContext.save()
    }

    func saveKeyStore(_ keyStore: KeyStore) throws {
        modelContext.insert(keyStore)
        try modelContext.save()
    }

    func saveToken(_ token: Token) throws {
        modelContext.insert(token)
        try modelContext.save()
    }

    func watchOnlyKeyStore() throws -> KeyStore {
        let watchOnlyRawKind = KeyStore.Kind.watchOnly.rawValue

        let predicate = #Predicate<KeyStore> {
            $0.rawKind == watchOnlyRawKind
        }

        let fetchDescriptor = FetchDescriptor<KeyStore>(predicate: predicate)
        let keyStores = try modelContext.fetch(fetchDescriptor)

        guard let keyStore = keyStores.first else {
            let keyStore = KeyStore(.watchOnly, name: "Watch-Only")
            modelContext.insert(keyStore)
            try modelContext.save()
            return keyStore
        }

        return keyStore
    }
}
