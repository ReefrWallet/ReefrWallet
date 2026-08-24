import Foundation
import SwiftData
import WalletKit

final class AccountService {
    private lazy var databaseService = DI.injectOrFail(DatabaseService.self)
    private lazy var hardwareService = DI.injectOrFail(HardwareService.self)

    @MainActor
    func makeAccount(
        _ blockchain: WKBlockchain,
        keyStore: KeyStore,
        watchOnlyAddress: String? = nil
    ) async throws -> Account {
        let accountIndex = try await nextAccountIndex(for: blockchain, in: keyStore)

        let address: String
        let derivationPath: String?

        switch keyStore.kind {
        case .local:
            guard let rawKey = keyStore.rawKey else {
                throw Error.invalidData
            }

            let result = try makeLocalAddress(blockchain: blockchain, rawKey: rawKey, accountIndex: accountIndex)

            address = result.address
            derivationPath = result.derivationPath
        case .trezor:
            guard let deviceId = keyStore.deviceId else {
                throw Error.invalidData
            }

            let device = try await hardwareService.connect(.trezor, deviceId: deviceId)
            let result = try await makeTrezorAddress(blockchain: blockchain, accountIndex: accountIndex, device: device)

            address = result.address
            derivationPath = result.derivationPath
        case .watchOnly:
            guard let watchOnlyAddress else {
                throw Error.invalidData
            }

            address = watchOnlyAddress
            derivationPath = nil
        }

        let account = Account(
            accountIndex: accountIndex,
            address: address,
            blockchain: blockchain,
            derivationPath: derivationPath,
            name: "\(blockchain.displayName) #\(accountIndex)"
        )

        return try await databaseService.insertAccount(account, keyStore: keyStore)
    }
}

private extension AccountService {
    struct AddressResult: Sendable {
        let address: String
        let derivationPath: String
    }

    func makeLocalAddress(blockchain: WKBlockchain, rawKey: Data, accountIndex: UInt64) throws -> AddressResult {
        let derivationPath = try DerivationPath(blockchain, accountIndex: accountIndex)
        let seed = try Seed(rawBytes: rawKey)

        let address: String
        switch blockchain {
        case .evm:
            let privateKey = try seed.masterKey(curve: .secp256k1).derive(derivationPath).privateKey()
            let signer = try EthereumPKeySigner(privateKey: privateKey, derivationPath: derivationPath)
            address = try signer.address().checksummed
        case .sui:
            let publicKey = try seed.masterKey(curve: .ed25519).derive(derivationPath).privateKey().publicKey
            address = try SuiAddress(publicKey: publicKey, curve: .ed25519).string
        default:
            throw Error.notImplemented
        }

        return AddressResult(address: address, derivationPath: derivationPath.string)
    }

    func makeTrezorAddress(
        blockchain: WKBlockchain,
        accountIndex: UInt64,
        device: HardwareDevice
    ) async throws -> AddressResult {
        let derivationPath = try DerivationPath(blockchain, accountIndex: accountIndex)

        switch blockchain {
        case .evm:
            let signer = try await EthereumTrezorSigner(device: device, derivationPath: derivationPath)
            return AddressResult(address: try signer.address().string, derivationPath: derivationPath.string)
        default:
            throw Error.notImplemented
        }
    }

    /// Return next account index that has not yet been configured
    func nextAccountIndex(for blockchain: WKBlockchain, in keyStore: KeyStore) async throws -> UInt64 {
        if case .watchOnly = keyStore.kind {
            return 0
        }

        guard let keyStoreId = keyStore.id else {
            throw Error.internalError
        }

        let accounts = try await databaseService.fetchAccounts(keyStoreId: keyStoreId, blockchain: blockchain)
        return UInt64(accounts.count)
    }
}
