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
    var deviceId: String? // trezor only
    var name: String
    var model: String? // trezor only
    var rawKind: String
    var rawKey: Data? // local only
    var transport: HardwareTransportKind? // trezor only
    var vendor: HardwareVendor? // trezor only

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
        self.vendor = vendor
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
            guard let model, let vendor else {
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

    func device() throws -> HardwareDevice {
        guard let deviceId, let vendor, let transport, let model else {
            printError("Missing device data")
            throw Error.invalidData
        }

        let info = HardwareDeviceInfo(
            id: deviceId,
            vendor: vendor,
            transport: transport,
            model: model
        )

        return HardwareDevice(info: info, delegate: nil) // TODO: set delegate
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
