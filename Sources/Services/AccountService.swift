import Foundation
import SwiftData
import WalletKit

final class AccountService {
    private lazy var hardwareService = DI.injectOrFail(HardwareService.self)
    private let databaseService: DatabaseService

    init(databaseService: DatabaseService? = nil) {
        self.databaseService = databaseService ?? DI.injectOrFail(DatabaseService.self)
    }

    func deleteAccount(_ account: Account) async throws {
        guard let accountId = account.id else {
            throw Error.invalidData
        }

        try await databaseService.deleteAccount(id: accountId)
    }

    func isValidAddress(_ address: String, for blockchain: WKBlockchain) -> Bool {
        do {
            switch blockchain {
            case .evm:
                _ = try EthereumAddress(string: address)
            case .sui:
                _ = try SuiAddress(string: address)
            default:
                return false
            }

            return true
        } catch {
            return false
        }
    }

    @MainActor @discardableResult
    func makeAccount(
        _ blockchain: WKBlockchain,
        keyStore: KeyStore,
        rpcURLOverride: URL? = nil,
        signatureScheme: Curve? = nil,
        watchOnlyAddress: String? = nil
    ) async throws -> Account {
        let accountIndex = try await nextAccountIndex(for: blockchain, in: keyStore)
        let effectiveSignatureScheme = try makeSignatureScheme(blockchain: blockchain, requested: signatureScheme)

        let address: String
        let derivationPath: String?

        switch keyStore.kind {
        case .local:
            guard let rawKey = keyStore.rawKey else {
                throw Error.invalidData
            }

            let result = try makeLocalAddress(
                blockchain: blockchain,
                rawKey: rawKey,
                accountIndex: accountIndex,
                signatureScheme: effectiveSignatureScheme
            )

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
            let trimmedAddress = watchOnlyAddress?.trimmingCharacters(in: .whitespacesAndNewlines)

            guard let trimmedAddress, !trimmedAddress.isEmpty else {
                throw Error.invalidData
            }

            guard isValidAddress(trimmedAddress, for: blockchain) else {
                throw Error.invalidAddress
            }

            address = trimmedAddress
            derivationPath = nil
        }

        guard let keyStoreId = keyStore.id else {
            throw Error.invalidData
        }

        var account = Account(
            accountIndex: accountIndex,
            address: address,
            blockchain: blockchain,
            derivationPath: derivationPath,
            keyStoreId: keyStoreId,
            name: "\(blockchain.displayName) #\(accountIndex + 1)",
            rpcURLOverride: rpcURLOverride,
            signatureScheme: effectiveSignatureScheme
        )

        account.id = try await databaseService.insertAccount(account, keyStore: keyStore)
        return account
    }
}

private extension AccountService {
    struct AddressResult: Sendable {
        let address: String
        let derivationPath: String
    }

    func makeSignatureScheme(blockchain: WKBlockchain, requested signatureScheme: Curve?) throws -> Curve? {
        switch blockchain {
        case .evm:
            guard signatureScheme == nil || signatureScheme == .secp256k1 else {
                throw Error.invalidData
            }

            return .secp256k1
        case .sui:
            return signatureScheme ?? .ed25519
        default:
            return nil
        }
    }

    func makeLocalAddress(
        blockchain: WKBlockchain,
        rawKey: Data,
        accountIndex: UInt64,
        signatureScheme: Curve?
    ) throws -> AddressResult {
        let curve: Curve
        switch blockchain {
        case .evm:
            curve = .secp256k1
        case .sui:
            guard let signatureScheme else {
                throw Error.invalidData
            }

            curve = signatureScheme
        default:
            throw Error.notImplemented
        }

        let derivationPath = try DerivationPath(blockchain, accountIndex: accountIndex, curve: curve)
        let seed = try Seed(rawBytes: rawKey)

        let address: String
        switch blockchain {
        case .evm:
            let privateKey = try seed.masterKey(curve: curve).derive(derivationPath).privateKey()
            let signer = try EthereumPKeySigner(privateKey: privateKey, derivationPath: derivationPath)
            address = try signer.address().checksummed
        case .sui:
            let publicKey = try seed.masterKey(curve: curve).derive(derivationPath).privateKey().publicKey
            address = try SuiAddress(publicKey: publicKey, curve: curve).string
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
        let derivationPath = try DerivationPath(blockchain, accountIndex: accountIndex, curve: .secp256k1)

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
            throw Error.invalidData
        }

        let accounts = try await databaseService.fetchAccounts(keyStoreId: keyStoreId, blockchain: blockchain)
        let nextIndex: UInt64 = accounts.reduce(into: 0, { partialResult, account in
            let accountIndex = account.accountIndex ?? 0

            if accountIndex >= partialResult {
                partialResult = accountIndex + 1
            }
        })

        return nextIndex
    }
}
