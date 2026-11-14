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
        guard let keyStore = try modelContext.fetch(FetchDescriptor<KeyStoreModel>())
            .first(where: { $0.persistentModelID == id }) else {
            return
        }

        if let sealed = keyStore.mnemonicEntropy {
            DI.inject(KeyVault.self)?.discard(sealed)
        }

        modelContext.delete(keyStore)
        try modelContext.save()
    }

    func fetchKeyStore(id: PersistentIdentifier) throws -> KeyStore? {
        try modelContext
            .fetch(FetchDescriptor<KeyStoreModel>())
            .first { $0.persistentModelID == id }
            .map(KeyStore.init(model:))
    }

    /// Inserts `keyStore`, numbering its name (`Local Key (#2)`) if another key store has it.
    @discardableResult
    func insertKeyStore(_ keyStore: KeyStore) throws -> PersistentIdentifier {
        let names = try Set(modelContext.fetch(FetchDescriptor<KeyStoreModel>()).map(\.name))
        let model = KeyStoreModel(from: keyStore)
        model.name = Self.uniqueName(keyStore.name, existing: names)
        modelContext.insert(model)

        // `save()` returning is the commit point; before it a cancelled or
        // failed insert removes only this model.
        do {
            try Task.checkCancellation()
            try modelContext.save()
        } catch {
            modelContext.delete(model)
            throw error
        }

        return model.persistentModelID
    }

    /// Ids of the hardware devices that already have a key store.
    func hardwareDeviceIds() throws -> [String] {
        try modelContext.fetch(FetchDescriptor<KeyStoreModel>()).compactMap(\.deviceId)
    }

    func renameKeyStore(id: PersistentIdentifier, name: String) throws {
        guard let keyStore = try modelContext.fetch(FetchDescriptor<KeyStoreModel>())
            .first(where: { $0.persistentModelID == id }) else {
            throw ReefrError.notFound
        }

        keyStore.name = name
        try modelContext.save()
    }

    func setKeyStoreCollapsed(id: PersistentIdentifier, isCollapsed: Bool) throws {
        guard let keyStore = try modelContext.fetch(FetchDescriptor<KeyStoreModel>())
            .first(where: { $0.persistentModelID == id }) else {
            throw ReefrError.notFound
        }

        keyStore.isCollapsed = isCollapsed
        try modelContext.save()
    }

    static func uniqueName(_ name: String, existing: Set<String>) -> String {
        guard existing.contains(name) else {
            return name
        }

        return (2...).lazy
            .map { String(localized: .keyStoreNumberedName(name, $0)) }
            .first { !existing.contains($0) } ?? name
    }

    func usdValue(keyStoreId: PersistentIdentifier) throws -> Decimal {
        guard let keyStoreModel = try modelContext.fetch(FetchDescriptor<KeyStoreModel>())
            .first(where: { $0.persistentModelID == keyStoreId }) else {
            throw ReefrError.notFound
        }

        return keyStoreModel.accounts.reduce(into: 0) { $0 += $1.usdValue() }
    }

    func watchOnlyKeyStore() throws -> KeyStore {
        let rawKind = KeyStore.Kind.watchOnly.rawValue
        let predicate = #Predicate<KeyStoreModel> { $0.rawKind == rawKind }

        if let model = try modelContext.fetch(FetchDescriptor(predicate: predicate)).first {
            return try KeyStore(model: model)
        }

        let model = KeyStoreModel(.watchOnly, name: String(localized: .keyStoreWatchOnlyName))
        modelContext.insert(model)
        try modelContext.save()

        return try KeyStore(model: model)
    }
}
