//
//  DatabaseService+KeyStore.swift
//  ReefrWallet
//
//  Created by Andrey Yurkevich on 18/09/2026.
//

import Foundation
import SwiftData

extension DatabaseService {
    func deleteKeyStore(id: PersistentIdentifier) throws {
        try modelContext.delete(model: KeyStoreModel.self, where: #Predicate { $0.id == id })
        try modelContext.save()
    }

    func fetchKeyStore(id: PersistentIdentifier) throws -> KeyStore? {
        try modelContext
            .fetch(FetchDescriptor(
                predicate: #Predicate<KeyStoreModel> { $0.id == id }
            ))
            .first
            .map(KeyStore.init(model:))
    }

    @discardableResult
    func insertKeyStore(_ keyStore: KeyStore) throws -> PersistentIdentifier {
        let model = KeyStoreModel(from: keyStore)
        modelContext.insert(model)
        try modelContext.save()
        return model.persistentModelID
    }

    func renameKeyStore(id: PersistentIdentifier, name: String) throws {
        let predicate = #Predicate<KeyStoreModel> { $0.id == id }

        guard let keyStore = try modelContext.fetch(FetchDescriptor(predicate: predicate)).first else {
            throw Error.notFound
        }

        keyStore.name = name
        try modelContext.save()
    }

    func usdValue(keyStoreId: PersistentIdentifier) throws -> Decimal {
        let predicate = #Predicate<KeyStoreModel> { $0.id == keyStoreId }

        guard let keyStoreModel = try modelContext.fetch(FetchDescriptor(predicate: predicate)).first else {
            throw Error.notFound
        }

        return keyStoreModel.accounts.reduce(into: 0) { $0 += $1.usdValue() }
    }

    func watchOnlyKeyStore() throws -> KeyStore {
        let rawKind = KeyStore.Kind.watchOnly.rawValue
        let predicate = #Predicate<KeyStoreModel> { $0.rawKind == rawKind }

        if let model = try modelContext.fetch(FetchDescriptor(predicate: predicate)).first {
            return try KeyStore(model: model)
        }

        let model = KeyStoreModel(.watchOnly, name: "Watch-Only")
        modelContext.insert(model)
        try modelContext.save()

        return try KeyStore(model: model)
    }
}
