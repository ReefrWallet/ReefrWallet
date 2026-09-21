import Foundation
import SwiftData
import WalletKit

final class AccountService {
    private lazy var balancesService = DI.injectOrFail(BalancesService.self)
    private lazy var hardwareService = DI.injectOrFail(HardwareService.self)
    private lazy var transactionSyncService = DI.injectOrFail(TransactionSyncService.self)
    private let databaseService: DatabaseService

    init(databaseService: DatabaseService? = nil) {
        self.databaseService = databaseService ?? DI.injectOrFail(DatabaseService.self)
    }

    func deleteAccount(_ account: Account) async throws {
        guard let accountId = account.id else {
            throw Error.invalidData
        }

        await transactionSyncService.stop(account)
        try await databaseService.deleteAccount(id: accountId)
    }

    func isValidAddress(_ address: String, for blockchain: WKBlockchain) -> Bool {
        do {
            switch blockchain {
            case .evm:
                _ = try EthereumAddress(string: address)
            case .sui:
                _ = try SuiAddress(string: address)
            case .tron:
                _ = try TronAddress(string: address)
            case .solana:
                _ = try SolanaAddress(string: address)
            case let .cardano(network):
                _ = try CardanoAccountDescriptor(
                    string: "cardano:\(network.storageIdentifier):\(address)"
                )
            case let .bitcoin(network):
                // Scoped to a plain address for now — importing a bare
                // account xpub as watch-only (rather than one address) is
                // a follow-up, since it would also need the UI to ask
                // which script type the xpub is for.
                _ = try BitcoinDescriptor(address: address, network: network)
            }

            return true
        } catch {
            return false
        }
    }

    @MainActor @discardableResult // swiftlint:disable:next function_body_length
    func makeAccount(
        _ blockchain: WKBlockchain,
        keyStore: KeyStore,
        rpcURLOverride: URL? = nil,
        signatureScheme: Curve? = nil,
        bitcoinScriptType: BitcoinScriptType? = nil,
        bitcoinBackend: BitcoinBackendKind? = nil,
        watchOnlyAddress: String? = nil
    ) async throws -> Account {
        let accountIndex = try await nextAccountIndex(for: blockchain, in: keyStore)
        let effectiveSignatureScheme = try makeSignatureScheme(blockchain: blockchain, requested: signatureScheme)

        let address: String
        let derivationPath: String?

        switch keyStore.kind {
        case .local:
            let rawKey = try keyStore.localSeed()

            let result: AddressResult
            if case let .cardano(network) = blockchain {
                guard let entropy = keyStore.mnemonicEntropy else {
                    throw Error.notSupported
                }

                let descriptor = try CardanoAccountDescriptor(
                    entropy: entropy,
                    network: network,
                    accountIndex: UInt32(accountIndex)
                )

                result = AddressResult(
                    address: descriptor.string,
                    derivationPath: "m/1852'/1815'/\(accountIndex)'"
                )
            } else {
                result = try makeLocalAddress(
                    blockchain: blockchain,
                    rawKey: rawKey,
                    accountIndex: accountIndex,
                    signatureScheme: effectiveSignatureScheme,
                    bitcoinScriptType: bitcoinScriptType
                )
            }

            address = result.address
            derivationPath = result.derivationPath
        case .trezor:
            guard let deviceId = keyStore.deviceId else {
                throw Error.invalidData
            }

            let device = try await hardwareService.connect(.trezor, deviceId: deviceId)
            let result = try await makeTrezorAddress(
                blockchain: blockchain,
                accountIndex: accountIndex,
                device: device,
                bitcoinScriptType: bitcoinScriptType
            )

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

            if case let .bitcoin(network) = blockchain {
                // Store the canonical `addr(...)` form so this account's
                // address round-trips through `BitcoinDescriptor(string:)`
                // the same way a local account's `wpkh(...)`/`tr(...)`
                // address already does (used by `AnyBlockchainClient`'s
                // generic string-addressed bridging).
                address = try BitcoinDescriptor(address: trimmedAddress, network: network).string
            } else if case let .cardano(network) = blockchain {
                address = try CardanoAccountDescriptor(
                    string: "cardano:\(network.storageIdentifier):\(trimmedAddress)"
                ).string
            } else {
                address = trimmedAddress
            }
            derivationPath = nil
        }

        guard let keyStoreId = keyStore.id else {
            throw Error.invalidData
        }

        let name = blockchain.isCustomEVM
            ? blockchain.displayName
            : (blockchain.isMainnet ? blockchain.name : blockchain.networkName)

        var account = Account(
            accountIndex: accountIndex,
            address: address,
            blockchain: blockchain,
            derivationPath: derivationPath,
            keyStoreId: keyStoreId,
            name: "\(name) #\(accountIndex + 1)",
            rpcURLOverride: rpcURLOverride,
            signatureScheme: effectiveSignatureScheme,
            bitcoinBackend: bitcoinBackend
        )

        account.id = try await databaseService.insertAccount(account, keyStore: keyStore)

        Task.detached {
            await self.transactionSyncService.start(account)

            do {
                try await self.balancesService.updateBalances(account)
            } catch {
                printError("Cannot update balances: \(error)")
            }
        }

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
        case .tron:
            guard signatureScheme == nil || signatureScheme == .secp256k1 else {
                throw Error.invalidData
            }
            return .secp256k1
        case .solana:
            guard signatureScheme == nil || signatureScheme == .ed25519 else {
                throw Error.invalidData
            }
            return .ed25519
        case .cardano:
            guard signatureScheme == nil || signatureScheme == .ed25519 else {
                throw Error.invalidData
            }
            return .ed25519
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
        signatureScheme: Curve?,
        bitcoinScriptType: BitcoinScriptType? = nil
    ) throws -> AddressResult {
        // Bitcoin has no single derivation path (an account xpub, not one
        // address, sits at its account-level path) — handled by its own
        // branch below rather than the shared `curve`/`DerivationPath`
        // flow the other chains use.
        if case let .bitcoin(network) = blockchain {
            return try makeLocalBitcoinAddress(
                network: network, rawKey: rawKey, accountIndex: accountIndex, scriptType: bitcoinScriptType
            )
        }

        let curve: Curve
        switch blockchain {
        case .evm:
            curve = .secp256k1
        case .tron:
            curve = .secp256k1
        case .solana:
            curve = .ed25519
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
        case .tron:
            let publicKey = try seed.masterKey(curve: curve).derive(derivationPath).privateKey().publicKey
            address = try TronAddress(publicKey: publicKey).string
        case .solana:
            let publicKey = try seed.masterKey(curve: curve).derive(derivationPath).privateKey().publicKey
            address = try SolanaAddress(publicKey: publicKey).string
        case .sui:
            let publicKey = try seed.masterKey(curve: curve).derive(derivationPath).privateKey().publicKey
            address = try SuiAddress(publicKey: publicKey, curve: curve).string
        default:
            throw Error.notImplemented
        }

        return AddressResult(address: address, derivationPath: derivationPath.string)
    }

    /// Derives the account-level xpub at
    /// `DerivationPath.bitcoinAccount(network:scriptType:accountIndex:)`,
    /// computes its BIP-32 master fingerprint, and builds the resulting
    /// `wpkh(...)`/`tr(...)` descriptor — stored as `Account.address` and
    /// re-parsed via `BitcoinDescriptor(string:network:)` everywhere else
    /// that needs it (the client, the builder, the signer).
    func makeLocalBitcoinAddress(
        network: BitcoinNetwork,
        rawKey: Data,
        accountIndex: UInt64,
        scriptType: BitcoinScriptType?
    ) throws -> AddressResult {
        guard let scriptType else {
            throw Error.invalidData
        }

        let seed = try Seed(rawBytes: rawKey)
        let masterKey = try seed.masterKey(curve: .secp256k1)
        let masterFingerprint = try BitcoinDescriptor.fingerprint(of: masterKey.publicKey)

        let accountDerivationPath = try DerivationPath.bitcoinAccount(
            network: network,
            scriptType: scriptType,
            accountIndex: UInt32(truncatingIfNeeded: accountIndex)
        )
        let accountKey = try masterKey.derive(accountDerivationPath)
        let accountPathText = String(accountDerivationPath.string.dropFirst(2)) // drop the leading "m/".

        let descriptor = try BitcoinDescriptor(
            xpub: accountKey.serializedPublic(),
            scriptType: scriptType,
            network: network,
            masterFingerprint: masterFingerprint,
            accountPath: accountPathText
        )

        return AddressResult(address: descriptor.string, derivationPath: accountDerivationPath.string)
    }

    func makeTrezorAddress(
        blockchain: WKBlockchain,
        accountIndex: UInt64,
        device: HardwareDevice,
        bitcoinScriptType: BitcoinScriptType? = nil
    ) async throws -> AddressResult {
        // Bitcoin has no single derivation path (an account xpub, not one
        // address, sits at its account-level path) — handled by its own
        // branch below rather than the shared `curve`/`DerivationPath`
        // flow the other chains use, matching `makeLocalAddress`.
        if case let .bitcoin(network) = blockchain {
            return try await makeTrezorBitcoinAddress(
                network: network, accountIndex: accountIndex, scriptType: bitcoinScriptType, device: device
            )
        }

        if case let .cardano(network) = blockchain {
            let derivationPath = try DerivationPath(
                string: "m/1852'/1815'/\(accountIndex)'"
            )
            let xpub = try await device.cardanoXpub(path: derivationPath)
            let descriptor = try CardanoAccountDescriptor(xpub: xpub, network: network)
            return AddressResult(address: descriptor.string, derivationPath: derivationPath.string)
        }

        let derivationPath = try DerivationPath(blockchain, accountIndex: accountIndex, curve: .secp256k1)

        switch blockchain {
        case .evm:
            let signer = try await EthereumTrezorSigner(device: device, derivationPath: derivationPath)
            return AddressResult(address: try signer.address().string, derivationPath: derivationPath.string)
        case .tron:
            let publicKey = try await device.publicKey(path: derivationPath, curve: .secp256k1)
            let address = try TronAddress(publicKey: publicKey)
            return AddressResult(address: address.string, derivationPath: derivationPath.string)
        case .solana:
            let signer = try await SolanaTrezorSigner(device: device, derivationPath: derivationPath)
            return AddressResult(address: try signer.address().string, derivationPath: derivationPath.string)
        default:
            throw Error.notImplemented
        }
    }

    /// Reads the account-level xpub for `scriptType`/`accountIndex` off
    /// `device` (``BitcoinTrezorSigner``'s two device reads: the master
    /// fingerprint, then the account xpub) and builds the resulting
    /// `wpkh(...)`/`tr(...)` descriptor — stored as `Account.address`, the
    /// same as ``makeLocalBitcoinAddress``'s software-derived equivalent.
    func makeTrezorBitcoinAddress(
        network: BitcoinNetwork,
        accountIndex: UInt64,
        scriptType: BitcoinScriptType?,
        device: HardwareDevice
    ) async throws -> AddressResult {
        guard let scriptType else {
            throw Error.invalidData
        }

        let signer = try await BitcoinTrezorSigner(
            network: network,
            scriptType: scriptType,
            accountIndex: UInt32(truncatingIfNeeded: accountIndex),
            device: device
        )

        let descriptor = try signer.address()
        return AddressResult(address: descriptor.string, derivationPath: signer.account.derivationPath.string)
    }

    /// Return next account index that has not yet been configured
    func nextAccountIndex(for blockchain: WKBlockchain, in keyStore: KeyStore) async throws -> UInt64 {
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
