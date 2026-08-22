//
//  KeyStore.swift
//  Reefr Wallet
//
//  Created by Andrey Yurkevich on 29.12.25.
//  Copyright © 2025 Reefr Wallet. All rights reserved.
//

import Foundation
import SwiftData
import WalletKit

@Model
final class KeyStore {
    /// Device id or `nil` for software key store
    var deviceId: String?

    var name: String
    /// Device model or `nil` for software key store
    var model: String?

    var rawKind: String
    /// Raw key bytes, `nil` for harware wallets
    var rawKey: Data?
    /// Harware transport, `nil` for software key store
    var rawTransport: String?
    /// Hardware vendor, `nil` for software key store
    var rawVendor: String?

    @Relationship(deleteRule: .cascade, inverse: \Account.keyStore)
    var accounts: [Account]?

    init(
        _ kind: Kind,
        deviceId: String? = nil,
        name: String,
        model: String? = nil,
        rawKey: Data? = nil,
        transport: HardwareTransportKind? = .usb,
        vendor: HardwareVendor? = nil
    ) {
        self.accounts = []
        self.deviceId = deviceId
        self.name = name
        self.model = model
        self.rawKey = rawKey
        self.rawKind = kind.rawValue
        self.rawVendor = vendor?.rawValue
    }
}

extension KeyStore {
    enum Kind: String, Codable, Comparable {
        case local
        case trezor
        case watchOnly

        static func < (lhs: KeyStore.Kind, rhs: KeyStore.Kind) -> Bool {
            lhs.priority < lhs.priority
        }
    }

    convenience init(_ info: HardwareDeviceInfo) {
        self.init(
            .trezor,
            deviceId: info.id,
            name: info.label ?? "\(info.vendor) \(info.model)",
            model: info.model,
            transport: info.transport,
            vendor: info.vendor
        )
    }

    var accountsUSDValue: Decimal {
        guard let accounts else {
            return 0
        }

        return accounts.reduce(0) { partialResult, account in
            partialResult + account.usdValue
        }
    }

    var description: String {
        switch kind {
        case .local:
            return "Local Key Store (on this computer)"
        case .trezor:
            guard let model, let rawVendor, let vendor = HardwareVendor(rawValue: rawVendor) else {
                preconditionFailure()
            }

            return "\(vendor) \(model)"
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

    var kind: Kind {
        Kind(rawValue: rawKind)!
    }

    /// Return next account index that has not yet been configured
    func nextAccountIndex(_ blockchain: Blockchain) -> UInt64 {
        if case .watchOnly = kind {
            return 0
        } else if let accounts {
            let count = accounts
                .filter {
                    $0.blockchainConfig.blockchain == blockchain
                }
                .count
            return UInt64(count)
        } else {
            return 0
        }
    }
}

private extension KeyStore.Kind {
    /// Priority in key stores list
    var priority: Int {
        switch self {
        case .local: 1
        case .trezor: 0
        case .watchOnly: 2
        }
    }
}

#if DEBUG

extension KeyStore {
    static func mockLocal() -> KeyStore {
        let keyStore = KeyStore(.local, name: "Local Key Store")
        keyStore.accounts = [.mockEth(keyStore: keyStore), .mockSui(keyStore: keyStore)]
        return keyStore
    }

    static func mockWatchOnly() -> KeyStore {
        let keyStore = KeyStore(.watchOnly, name: "Watch-Only Key Store")
        keyStore.accounts = [.mockEth(keyStore: keyStore), .mockSui(keyStore: keyStore)]
        return keyStore
    }
}

#endif
