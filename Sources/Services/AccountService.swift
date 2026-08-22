//
//  AccountService.swift
//  Reefr Wallet
//
//  Created by Andrey Yurkevich on 25.02.26.
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import WalletKit

final class AccountService {
    private lazy var blockchainConfigService = DI.injectOrFail(BlockchainConfigService.self)
    private lazy var databaseService = DI.injectOrFail(DatabaseService.self)
    private lazy var hardwareService = DI.injectOrFail(HardwareService.self)

    func makeAccount(
        _ blockchain: Blockchain,
        keyStore: KeyStore
    ) async throws -> Account {
        let storedKeyStore = try await databaseService.fetchKeyStore(id: keyStore.id)
        let blockchainConfig = try await blockchainConfigService.getConfig(for: blockchain)
        let accountIndex = storedKeyStore.nextAccountIndex(blockchain)
        let name = "\(blockchainConfig.displayName) #\(accountIndex + 1)"

        let account = Account(
            accountIndex: accountIndex,
            address: "", // we'll set address later on
            blockchainConfig: blockchainConfig,
            keyStore: storedKeyStore,
            name: name
        )

        // Figure out and save own address and derivation path
        switch storedKeyStore.kind {
        case .local:
            try setLocalAddress(account)
        case .trezor:
            guard let deviceId = storedKeyStore.deviceId else {
                printError("Missing device id")
                throw Error.invalidData
            }

            let device = try await hardwareService.connect(.trezor, deviceId: deviceId)
            try await setTrezorAddress(account, device: device)
        case .watchOnly:
            break
        }

        storedKeyStore.accounts?.append(account)
        try await databaseService.saveChanges()

        return account
    }
}

private extension AccountService {
    /// Fills in ``Account``'s derivation path and address
    func setLocalAddress(_ account: Account) throws {
        guard let rawKey = account.keyStore?.rawKey else {
            printError("Missing key data")
            throw Error.invalidData
        }

        guard let accountIndex = account.accountIndex else {
            printError("Missing account index")
            throw Error.invalidData
        }

        let derivationPath = try DerivationPath(account.blockchainConfig.blockchain, accountIndex: accountIndex)
        account.derivationPath = derivationPath.string

        let seed = try Seed(rawBytes: rawKey)

        switch account.blockchainConfig.blockchain {
        case .ethereum:
            let privateKey = try seed.masterKey(curve: .secp256k1).derive(derivationPath).privateKey()
            let signer = try EthereumPKeySigner(privateKey: privateKey, derivationPath: derivationPath)
            account.address = try signer.address().checksummed
        case let .sui(curve):
            let publicKey = try seed.masterKey(curve: curve).derive(derivationPath).privateKey().publicKey
            let address = try SuiAddress(publicKey: publicKey, curve: curve)
            account.address = address.string
        default:
            throw Error.notImplemented
        }
    }

    /// Fills in ``Account``'s derivation path and address from ``HardwareDevice``
    func setTrezorAddress(_ account: Account, device: HardwareDevice) async throws {
        guard let accountIndex = account.accountIndex else {
            printError("Missing account index")
            throw Error.invalidData
        }

        let derivationPath = try DerivationPath(account.blockchainConfig.blockchain, accountIndex: accountIndex)
        account.derivationPath = derivationPath.string

        switch account.blockchainConfig.blockchain {
        case .ethereum:
            do {
                let signer = try await EthereumTrezorSigner(device: device, derivationPath: derivationPath)
                account.address = try signer.address().string
                account.derivationPath = derivationPath.string
            } catch {
                printError("Can't create signer: \(error)")
                throw error
            }

        default:
            throw Error.notImplemented
        }
    }
}
