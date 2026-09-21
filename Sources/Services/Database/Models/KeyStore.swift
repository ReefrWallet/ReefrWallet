//
//  KeyStoreModel.swift
//  Reefr Wallet
//
//  Created by Andrey Yurkevich on 29.12.25.
//  Copyright © 2025 Reefr Wallet. All rights reserved.
//

import Foundation
import SwiftData
import WalletKit

// MARK: - KeyStore

struct KeyStore: Equatable, Hashable, Sendable {
    enum Kind: String, Codable {
        case local
        case trezor
        case watchOnly
    }

    let accounts: [Account]
    let deviceId: String?
    /// `nil` for newly-created keystores that haven't been persisted yet;
    /// set after the first fetch from the database.
    var id: PersistentIdentifier?
    let kind: Kind
    let name: String
    let mnemonicEntropy: Data?
    let mnemonicWordlist: Wordlist?
    let transport: HardwareTransportKind?
    let vendor: HardwareVendor?

    init(
        deviceId: String?,
        id: PersistentIdentifier? = nil,
        kind: Kind,
        name: String,
        mnemonicEntropy: Data? = nil,
        mnemonicWordlist: Wordlist? = nil,
        transport: HardwareTransportKind?,
        vendor: HardwareVendor?
    ) {
        self.accounts = []
        self.deviceId = deviceId
        self.id = id
        self.kind = kind
        self.name = name
        self.mnemonicEntropy = mnemonicEntropy
        self.mnemonicWordlist = mnemonicWordlist
        self.transport = transport
        self.vendor = vendor
    }
}

// MARK: - KeyStore.Kind

extension KeyStore.Kind: Comparable {
    /// Priority in key stores list
    private var priority: Int {
        switch self {
        case .local: 1
        case .trezor: 0
        case .watchOnly: 2
        }
    }

    static func < (lhs: KeyStore.Kind, rhs: KeyStore.Kind) -> Bool {
        lhs.priority < rhs.priority
    }
}

// MARK: - KeyStoreModel

@Model
final class KeyStoreModel {
    /// Device id or `nil` for software key store
    var deviceId: String?
    /// Device name
    var name: String
    /// Serialized ``Kind``
    var rawKind: String
    /// Original BIP-39 entropy for Cardano's Icarus key derivation.
    var mnemonicEntropy: Data?
    /// Serialized BIP-39 wordlist used to reconstruct the conventional seed.
    var rawMnemonicWordlist: String?
    /// Harware transport, `nil` for software key store
    var rawTransport: String?
    /// Hardware vendor, `nil` for software key store
    var rawVendor: String?

    @Relationship(deleteRule: .cascade, inverse: \AccountModel.keyStore)
    var accounts: [AccountModel]

    init(
        _ kind: KeyStore.Kind,
        deviceId: String? = nil,
        name: String,
        mnemonicEntropy: Data? = nil,
        mnemonicWordlist: Wordlist? = nil,
        transport: HardwareTransportKind? = .usb,
        vendor: HardwareVendor? = nil
    ) {
        self.accounts = []
        self.deviceId = deviceId
        self.name = name
        self.mnemonicEntropy = mnemonicEntropy
        self.rawMnemonicWordlist = mnemonicWordlist?.storageIdentifier
        self.rawKind = kind.rawValue
        self.rawTransport = transport?.rawValue
        self.rawVendor = vendor?.rawValue
    }
}

// MARK: - Init

extension KeyStore {
    init(model: KeyStoreModel) throws {
        accounts = try model.accounts.compactMap { try Account(model: $0) }
        deviceId = model.deviceId
        id = model.id
        kind = Kind(rawValue: model.rawKind)!
        name = model.name
        mnemonicEntropy = model.mnemonicEntropy
        mnemonicWordlist = model.rawMnemonicWordlist.flatMap(Wordlist.init(storageIdentifier:))

        if let rawTransport = model.rawTransport {
            transport = HardwareTransportKind(rawValue: rawTransport)
        } else {
            transport = nil
        }

        if let rawVendor = model.rawVendor {
            vendor = HardwareVendor(rawValue: rawVendor)
        } else {
            vendor = nil
        }
    }
}

extension KeyStoreModel {
    convenience init(_ info: HardwareDeviceInfo) {
        self.init(
            .trezor,
            deviceId: info.id,
            name: info.label ?? "\(info.vendor) \(info.model)",
            transport: info.transport,
            vendor: info.vendor
        )
    }

    convenience init(from config: KeyStore) {
        self.init(
            config.kind,
            deviceId: config.deviceId,
            name: config.name,
            mnemonicEntropy: config.mnemonicEntropy,
            mnemonicWordlist: config.mnemonicWordlist,
            transport: config.transport,
            vendor: config.vendor
        )
    }
}

// MARK: - KeyStore Helpers

extension KeyStore {
    func localSeed() throws -> Data {
        guard kind == .local, let mnemonicEntropy else {
            throw Error.invalidData
        }

        return try Mnemonic.fromEntropy(
            mnemonicEntropy,
            wordlist: mnemonicWordlist ?? .english
        ).toSeed().exportRaw()
    }

    var description: String {
        switch kind {
        case .local:
            return "Local Key Store (on this computer)"
        case .trezor:
            return name
        case .watchOnly:
            preconditionFailure()
        }
    }

    var isHardware: Bool {
        kind == .trezor
    }

    var isLocal: Bool {
        kind == .local
    }

    var isWatchOnly: Bool {
        kind == .watchOnly
    }
}

// MARK: - KeyStoreModel Helpers

extension KeyStoreModel {
    var kind: KeyStore.Kind {
        KeyStore.Kind(rawValue: rawKind)!
    }

    var isWatchOnly: Bool {
        kind == .watchOnly
    }
}

// MARK: - Preview Mocks

/* #if DEBUG

extension KeyStore {
    static func mockLocal() throws -> KeyStore {
        let keyStore = KeyStoreModel(.local, name: "Local Key Store")
        keyStore.accounts = try [.mockEth(keyStore: keyStore), .mockSui(keyStore: keyStore)]
        return keyStore
    }

    static func mockWatchOnly() throws -> KeyStoreModel {
        let keyStore = KeyStoreModel(.watchOnly, name: "Watch-Only Key Store")
        keyStore.accounts = try [.mockEth(keyStore: keyStore), .mockSui(keyStore: keyStore)]
        return keyStore
    }
}

#endif */
