// swiftlint:disable file_length
import SwiftData
import WalletKit

/// Creates, validates and deletes blockchain accounts.
final class AccountService {
    private lazy var balancesService = DI.injectOrFail(BalancesService.self)
    private lazy var hardwareService = DI.injectOrFail(HardwareService.self)
    private lazy var transactionSyncService = DI.injectOrFail(TransactionSyncService.self)
    private let databaseService: DatabaseService

    /// - Parameter databaseService: The database to use; the DI container's by default.
    init(databaseService: DatabaseService? = nil) {
        self.databaseService = databaseService ?? DI.injectOrFail(DatabaseService.self)
    }

    /// Stops `account`'s transaction sync and deletes it from the database.
    ///
    /// - Parameter account: A stored account.
    /// - Throws: ``ReefrError/invalidData`` if `account` was never stored,
    ///   or a database error.
    func deleteAccount(_ account: Account) async throws {
        guard let accountId = account.id else {
            throw ReefrError.invalidData
        }

        await transactionSyncService.stop(account)
        try await databaseService.deleteAccount(id: accountId)
        await disconnectDapps(from: [account])
    }

    /// Disconnects browser and WalletConnect dapps from the addresses of
    /// deleted `accounts`, unless a remaining account still uses them.
    ///
    /// - Parameter accounts: Accounts already removed from the database.
    func disconnectDapps(from accounts: [Account]) async {
        let remaining = Set(((try? await databaseService.fetchAllAccounts()) ?? []).map(\.address))
        let addresses = Set(accounts.map(\.address)).subtracting(remaining)

        guard !addresses.isEmpty else {
            return
        }

        await MainActor.run {
            DI.injectOrFail(ConnectedDappStore.self).revokeGrants(addresses: addresses)
        }

        let walletConnect = await MainActor.run { DI.injectOrFail(WalletConnectService.self) }
        await walletConnect.disconnectSessions(addresses: addresses)
    }

    /// Whether `address` parses as an address on `blockchain`.
    ///
    /// Cardano expects an account descriptor body; Bitcoin a plain address,
    /// not an xpub.
    ///
    /// - Parameters:
    ///   - address: The address to check.
    ///   - blockchain: The blockchain `address` should belong to.
    /// - Returns: `true` if `address` is valid on `blockchain`.
    func isValidAddress(_ address: String, for blockchain: Blockchain) -> Bool {
        do {
            switch blockchain {
            case .aptos:
                _ = try AptosAddress(string: address)
            case .evm:
                _ = try EthereumAddress(string: address)
            case .sui:
                _ = try SuiAddress(string: address)
            case .tron:
                _ = try TronAddress(string: address)
            case .solana:
                _ = try SolanaAddress(string: address)
            case let .cardano(network):
                _ = try CardanoAccountDescriptor(string: "cardano:\(network.storageIdentifier):\(address)")
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

    /// Derives, stores and starts syncing the next account on `keyStore`.
    ///
    /// Uses the next unused account index for `blockchain` in `keyStore`.
    /// Local keys derive from the key store's secret; Trezor keys read
    /// from the device inside a ``HardwareService`` session, prompting to
    /// connect or confirm as needed; watch-only key stores store
    /// `watchOnlyAddress` in canonical form. Transaction sync and a balance
    /// refresh start in the background.
    ///
    /// - Parameters:
    ///   - blockchain: The blockchain to create the account on.
    ///   - keyStore: The stored key store to create the account in.
    ///   - rpcURLOverride: A custom RPC endpoint for this account.
    ///   - signatureScheme: The curve to use; only Aptos and Sui offer a
    ///     choice, other chains accept `nil` or their only curve.
    ///   - bitcoinScriptType: The script type; required for Bitcoin.
    ///   - bitcoinBackend: The Bitcoin indexing backend.
    ///   - watchOnlyAddress: The address to watch; required for watch-only
    ///     key stores, ignored otherwise.
    ///   - accountName: A name to use instead of the numbered default.
    ///   - derivationPath: The account path; must match the blockchain's
    ///     shape, see ``DerivationPath/validate(for:curve:scriptType:)``.
    ///     Defaults to the next account's path. Unused for watch-only.
    /// - Returns: The stored account.
    /// - Throws: ``ReefrError/alreadyExists`` if the key store already has an
    ///   account on `blockchain` with the same custom path;
    ///   ``ReefrError/invalidData`` for an unsupported curve, a
    ///   missing script type, device ID or watch-only address, or an
    ///   unstored key store; ``ReefrError/invalidAddress`` for an invalid
    ///   watch-only address; ``ReefrError/notSupported`` for a Cardano
    ///   account on a local key store without mnemonic entropy;
    ///   ``ReefrError/notImplemented`` for a chain the key store kind can't
    ///   derive; or a derivation, device or database error.
    @MainActor @discardableResult // swiftlint:disable:next function_body_length
    func makeAccount(
        _ blockchain: Blockchain,
        keyStore: KeyStore,
        rpcURLOverride: URL? = nil,
        signatureScheme: Curve? = nil,
        bitcoinScriptType: BitcoinScriptType? = nil,
        bitcoinBackend: BitcoinBackendKind? = nil,
        watchOnlyAddress: String? = nil,
        accountName nameOverride: String? = nil,
        derivationPath: DerivationPath? = nil
    ) async throws -> Account {
        let effectiveSignatureScheme = try makeSignatureScheme(blockchain: blockchain, requested: signatureScheme)
        let existing = try await existingAccounts(for: blockchain, in: keyStore)

        let path: DerivationPath?
        if keyStore.isWatchOnly {
            path = nil
        } else if let derivationPath {
            try derivationPath.validate(
                for: blockchain,
                curve: effectiveSignatureScheme,
                scriptType: bitcoinScriptType
            )

            guard !existing.contains(where: { $0.derivationPath == derivationPath }) else {
                throw ReefrError.alreadyExists
            }

            path = derivationPath
        } else {
            path = try nextPath(
                for: blockchain,
                after: existing,
                curve: effectiveSignatureScheme,
                scriptType: bitcoinScriptType
            )
        }

        let address: String

        switch keyStore.kind {
        case .local:
            guard let path else {
                throw ReefrError.invalidData
            }

            if case let .cardano(network) = blockchain {
                let entropy = try await keyStore.localEntropy(reason: "Authenticate to add an account")

                address = try CardanoAccountDescriptor(
                    entropy: entropy,
                    network: network,
                    path: path
                ).string
            } else {
                let rawKey = try await keyStore.localSeed(reason: "Authenticate to add an account")

                address = try makeLocalAddress(
                    blockchain: blockchain,
                    rawKey: rawKey,
                    path: path,
                    signatureScheme: effectiveSignatureScheme,
                    bitcoinScriptType: bitcoinScriptType
                )
            }

        case .trezor:
            guard let deviceId = keyStore.deviceId, let path else {
                throw ReefrError.invalidData
            }

            address = try await hardwareService.session(showsWait: true) {
                let device = try await hardwareService.connect(.trezor, deviceId: deviceId)
                return try await makeTrezorAddress(
                    blockchain: blockchain,
                    path: path,
                    device: device,
                    bitcoinScriptType: bitcoinScriptType
                )
            }

        case .watchOnly:
            let trimmedAddress = watchOnlyAddress?.trimmingCharacters(in: .whitespacesAndNewlines)

            guard let trimmedAddress, !trimmedAddress.isEmpty else {
                throw ReefrError.invalidData
            }

            guard isValidAddress(trimmedAddress, for: blockchain) else {
                throw ReefrError.invalidAddress
            }

            if case let .bitcoin(network) = blockchain {
                // Store the canonical `addr(...)` form so this account's
                // address round-trips through `BitcoinDescriptor(string:)`
                // the same way a local account's `wpkh(...)`/`tr(...)`
                // address already does (used by the clients' generic
                // string-addressed bridging).
                address = try BitcoinDescriptor(address: trimmedAddress, network: network).string
            } else if case .aptos = blockchain {
                // Canonical AIP-40 form, so lookups match chain-reported addresses.
                address = try AptosAddress(string: trimmedAddress).string
            } else if case let .cardano(network) = blockchain {
                address = try CardanoAccountDescriptor(
                    string: "cardano:\(network.storageIdentifier):\(trimmedAddress)"
                ).string
            } else {
                address = trimmedAddress
            }
        }

        guard let keyStoreId = keyStore.id else {
            throw ReefrError.invalidData
        }

        let name = blockchain.isCustomEVM
            ? blockchain.displayName
            : (blockchain.isMainnet ? blockchain.name : blockchain.networkName)

        // A path that isn't a default one is named after itself; watch-only
        // accounts have no path and are numbered by count.
        let accountName: String
        if let nameOverride {
            accountName = nameOverride
        } else if let path {
            let index = defaultAccountIndex(
                of: path,
                for: blockchain,
                curve: effectiveSignatureScheme,
                scriptType: bitcoinScriptType
            )

            accountName = index.map { "\(name) #\($0 + 1)" } ?? "\(name) \(path.string)"
        } else {
            accountName = "\(name) #\(existing.count + 1)"
        }

        var account = Account(
            address: address,
            blockchain: blockchain,
            derivationPath: path,
            keyStoreId: keyStoreId,
            name: accountName,
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

    /// The derivation path ``makeAccount`` would use for the next account on
    /// `keyStore`; `nil` on error.
    @MainActor
    func nextDerivationPath(
        _ blockchain: Blockchain,
        keyStore: KeyStore,
        signatureScheme: Curve? = nil,
        bitcoinScriptType: BitcoinScriptType? = nil
    ) async -> DerivationPath? {
        guard let existing = try? await existingAccounts(for: blockchain, in: keyStore) else {
            return nil
        }

        return try? nextPath(
            for: blockchain,
            after: existing,
            curve: try? makeSignatureScheme(blockchain: blockchain, requested: signatureScheme),
            scriptType: bitcoinScriptType
        )
    }
}

private extension AccountService {
    /// The default path of account `accountIndex` on `blockchain`.
    func defaultPath(
        for blockchain: Blockchain,
        accountIndex: UInt64,
        curve: Curve?,
        scriptType: BitcoinScriptType?
    ) throws -> DerivationPath {
        switch blockchain {
        case let .bitcoin(network):
            guard let scriptType else {
                throw ReefrError.invalidData
            }

            return try .bitcoinAccount(
                network: network,
                scriptType: scriptType,
                accountIndex: UInt32(truncatingIfNeeded: accountIndex)
            )

        case .cardano:
            return try .cardanoAccount(accountIndex: UInt32(truncatingIfNeeded: accountIndex))
        default:
            return try DerivationPath(blockchain, accountIndex: accountIndex, curve: curve)
        }
    }

    /// The index `N` if `path` is the default path of account `N`, else `nil`.
    /// Without a `scriptType`, a Bitcoin path may be either script type's.
    func defaultAccountIndex(
        of path: DerivationPath,
        for blockchain: Blockchain,
        curve: Curve?,
        scriptType: BitcoinScriptType?
    ) -> UInt64? {
        // Position of the segment holding the account index.
        let position = switch blockchain {
        case .aptos, .solana: 2
        default: path.segments.count - 1
        }

        guard path.segments.indices.contains(position) else {
            return nil
        }

        let index = UInt64(path.segments[position].index)
        let scriptTypes: [BitcoinScriptType?] = if case .bitcoin = blockchain, scriptType == nil {
            [.p2wpkh, .p2tr]
        } else {
            [scriptType]
        }

        let matches = scriptTypes.contains {
            (try? defaultPath(for: blockchain, accountIndex: index, curve: curve, scriptType: $0)) == path
        }

        return matches ? index : nil
    }

    func existingAccounts(for blockchain: Blockchain, in keyStore: KeyStore) async throws -> [Account] {
        guard let keyStoreId = keyStore.id else {
            throw ReefrError.invalidData
        }

        return try await databaseService.fetchAccounts(keyStoreId: keyStoreId, blockchain: blockchain)
    }

    /// The default path after the highest default-path account among `accounts`.
    func nextPath(
        for blockchain: Blockchain,
        after accounts: [Account],
        curve: Curve?,
        scriptType: BitcoinScriptType?
    ) throws -> DerivationPath {
        let indices = accounts.compactMap { account in
            account.derivationPath.flatMap {
                defaultAccountIndex(of: $0, for: blockchain, curve: account.signatureScheme, scriptType: nil)
            }
        }

        return try defaultPath(
            for: blockchain,
            accountIndex: indices.max().map { $0 + 1 } ?? 0,
            curve: curve,
            scriptType: scriptType
        )
    }

    func makeLocalAddress(
        blockchain: Blockchain,
        rawKey: Data,
        path: DerivationPath,
        signatureScheme: Curve?,
        bitcoinScriptType: BitcoinScriptType? = nil
    ) throws -> String {
        // Bitcoin has no single derivation path (an account xpub, not one
        // address, sits at its account-level path) — handled by its own
        // branch below rather than the shared `curve`/`DerivationPath`
        // flow the other chains use.
        if case let .bitcoin(network) = blockchain {
            return try makeLocalBitcoinAddress(
                network: network, rawKey: rawKey, path: path, scriptType: bitcoinScriptType
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
        case .aptos, .sui:
            guard let signatureScheme else {
                throw ReefrError.invalidData
            }

            curve = signatureScheme
        default:
            throw ReefrError.notImplemented
        }

        let seed = try Seed(rawBytes: rawKey)

        let address: String
        switch blockchain {
        case .aptos:
            let publicKey = try seed.masterKey(curve: curve).derive(path).privateKey().publicKey
            address = try AptosAddress(publicKey: publicKey, curve: curve).string
        case .evm:
            let privateKey = try seed.masterKey(curve: curve).derive(path).privateKey()
            let signer = try EthereumPKeySigner(privateKey: privateKey, derivationPath: path)
            address = try signer.address().checksummed
        case .tron:
            let publicKey = try seed.masterKey(curve: curve).derive(path).privateKey().publicKey
            address = try TronAddress(publicKey: publicKey).string
        case .solana:
            let publicKey = try seed.masterKey(curve: curve).derive(path).privateKey().publicKey
            address = try SolanaAddress(publicKey: publicKey).string
        case .sui:
            let publicKey = try seed.masterKey(curve: curve).derive(path).privateKey().publicKey
            address = try SuiAddress(publicKey: publicKey, curve: curve).string
        default:
            throw ReefrError.notImplemented
        }

        return address
    }

    /// Derives the account-level xpub at `path`,
    /// computes its BIP-32 master fingerprint, and builds the resulting
    /// `wpkh(...)`/`tr(...)` descriptor — stored as `Account.address` and
    /// re-parsed via `BitcoinDescriptor(string:network:)` everywhere else
    /// that needs it (the client, the builder, the signer).
    func makeLocalBitcoinAddress(
        network: BitcoinNetwork,
        rawKey: Data,
        path accountDerivationPath: DerivationPath,
        scriptType: BitcoinScriptType?
    ) throws -> String {
        guard let scriptType else {
            throw ReefrError.invalidData
        }

        let seed = try Seed(rawBytes: rawKey)
        let masterKey = try seed.masterKey(curve: .secp256k1)
        let masterFingerprint = try BitcoinDescriptor.fingerprint(of: masterKey.publicKey)

        let accountKey = try masterKey.derive(accountDerivationPath)
        let accountPathText = String(accountDerivationPath.string.dropFirst(2)) // drop the leading "m/".

        let descriptor = try BitcoinDescriptor(
            xpub: accountKey.serializedPublic(),
            scriptType: scriptType,
            network: network,
            masterFingerprint: masterFingerprint,
            accountPath: accountPathText
        )

        return descriptor.string
    }

    func makeSignatureScheme(blockchain: Blockchain, requested signatureScheme: Curve?) throws -> Curve? {
        switch blockchain {
        case .evm:
            guard signatureScheme == nil || signatureScheme == .secp256k1 else {
                throw ReefrError.invalidData
            }

            return .secp256k1
        case .tron:
            guard signatureScheme == nil || signatureScheme == .secp256k1 else {
                throw ReefrError.invalidData
            }

            return .secp256k1
        case .solana:
            guard signatureScheme == nil || signatureScheme == .ed25519 else {
                throw ReefrError.invalidData
            }

            return .ed25519
        case .cardano:
            guard signatureScheme == nil || signatureScheme == .ed25519 else {
                throw ReefrError.invalidData
            }

            return .ed25519
        case .aptos, .sui:
            return signatureScheme ?? .ed25519
        default:
            return nil
        }
    }

    func makeTrezorAddress(
        blockchain: Blockchain,
        path: DerivationPath,
        device: HardwareDevice,
        bitcoinScriptType: BitcoinScriptType? = nil
    ) async throws -> String {
        // Bitcoin has no single derivation path (an account xpub, not one
        // address, sits at its account-level path) — handled by its own
        // branch below rather than the shared `curve`/`DerivationPath`
        // flow the other chains use, matching `makeLocalAddress`.
        if case let .bitcoin(network) = blockchain {
            return try await makeTrezorBitcoinAddress(
                network: network, path: path, scriptType: bitcoinScriptType, device: device
            )
        }

        if case let .cardano(network) = blockchain {
            let xpub = try await device.cardanoXpub(path: path)
            return try CardanoAccountDescriptor(xpub: xpub, network: network).string
        }

        switch blockchain {
        case .evm:
            let signer = try await EthereumTrezorSigner(device: device, derivationPath: path)
            return try signer.address().string
        case .tron:
            let publicKey = try await device.publicKey(path: path, curve: .secp256k1)
            return try TronAddress(publicKey: publicKey).string
        case .solana:
            let signer = try await SolanaTrezorSigner(device: device, derivationPath: path)
            return try signer.address().string
        default:
            throw ReefrError.notImplemented
        }
    }

    /// Reads the account-level xpub for `scriptType` at `path` off
    /// `device` (``BitcoinTrezorSigner``'s two device reads: the master
    /// fingerprint, then the account xpub) and builds the resulting
    /// `wpkh(...)`/`tr(...)` descriptor — stored as `Account.address`, the
    /// same as ``makeLocalBitcoinAddress``'s software-derived equivalent.
    func makeTrezorBitcoinAddress(
        network: BitcoinNetwork,
        path: DerivationPath,
        scriptType: BitcoinScriptType?,
        device: HardwareDevice
    ) async throws -> String {
        guard let scriptType else {
            throw ReefrError.invalidData
        }

        let signer = try await BitcoinTrezorSigner(
            network: network,
            scriptType: scriptType,
            path: path,
            device: device
        )

        return try signer.address().string
    }
}
