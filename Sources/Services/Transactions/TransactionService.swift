//
//  TransactionService.swift
//  Reefr Wallet
//
//  Created by Andrey Yurkevich on 26.02.26.
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import WalletKit

// MARK: - TransactionService

/// `@unchecked Sendable`: a DI-injected singleton, called from concurrent
/// contexts already (like every other service in `Sources/Services`); needed
/// here only because ``EthereumDappProvider`` (`Sendable`) stores one.
final class TransactionService: @unchecked Sendable {
    private lazy var clientProvider = DI.injectOrFail(BlockchainClientProvider.self)
    private lazy var hardwareService = DI.injectOrFail(HardwareService.self)
    private lazy var transactionSyncService = DI.injectOrFail(TransactionSyncService.self)
    private let databaseService: DatabaseService

    init(databaseService: DatabaseService? = nil) {
        self.databaseService = databaseService ?? DI.injectOrFail(DatabaseService.self)
    }

    /// Builds unsigned transaction bytes for a transfer of `token` from
    /// `account` to `recipient`, optionally honoring user-supplied `fees`.
    ///
    /// When `fees` are provided, the relevant fee fields are forwarded to
    /// the builder as ``BlockchainTransactionBuilderOptions`` so the
    /// user-edited values take priority over freshly fetched network rates.
    func makeTransaction(
        token: Token,
        decimalAmount: String,
        cardanoRecipientLovelace: String? = nil,
        recipient: String,
        account: Account,
        fees: Fees? = nil
    ) async throws -> Data {
        guard let blockchain = token.blockchain else {
            throw ReefrError.invalidData
        }

        let amount = try token.smallestUnitAmount(from: decimalAmount)
        // nil token identifier → native asset; non-nil → ERC-20 / Sui coin type.
        let tokenId: String? = token.isNativeToken ? nil : token.address

        var options = try fees.map { try buildOptions($0, blockchain: blockchain) } ?? []

        if case .cardano = blockchain, !token.isNativeToken {
            guard let cardanoRecipientLovelace, let lovelace = UInt64(cardanoRecipientLovelace) else {
                throw ReefrError.invalidData
            }

            options.append(.cardanoRecipientLovelace(lovelace))
        }

        let builder = try clientProvider.makeTransactionBuilder(
            blockchain: blockchain,
            rpcURL: account.rpcURLOverride,
            backend: account.bitcoinBackend
        )

        return try await builder.buildTransfer(
            sender: account.address,
            recipient: recipient,
            amount: amount,
            token: tokenId,
            options: options
        )
    }

    /// Signs `txRequest` with the key associated with `account` and returns
    /// the signed bytes ready for ``sendTransaction(_:_:account:)``.
    ///
    /// - For Ethereum: returns a self-contained signed envelope (pass as
    ///   `txSignature` to ``sendTransaction``).
    /// - For Sui: returns the serialized Sui signature (pass as `txSignature`
    ///   alongside the original `txRequest` to ``sendTransaction``).
    func signTransaction(_ txRequest: Data, account: Account) async throws -> Data {
        if case .cardano = account.blockchain {
            // Cardano uses special signing flow
            return try await signCardanoTransaction(txRequest, account: account)
        }

        return try await withSigner(for: account) { signer in
            try await signer.sign(transaction: txRequest)
        }
    }

    /// Broadcasts a signed transaction and returns its hash / digest.
    ///
    /// - Parameters:
    ///   - txRequest: The unsigned transaction bytes produced by
    ///     ``makeTransaction(token:decimalAmount:recipient:account:fees:)``.
    ///   - txSignature: The bytes returned by ``signTransaction(_:account:)``.
    ///   - account: The sending account.
    /// - Returns: The transaction hash (Ethereum) or digest (Sui).
    func sendTransaction(_ txRequest: Data, _ txSignature: Data, account: Account) async throws -> String {
        let client = try clientProvider.makeClient(
            blockchain: account.blockchain,
            rpcURL: account.rpcURLOverride,
            backend: account.bitcoinBackend
        )

        let identifier = try await client.broadcast(transaction: txRequest, signature: txSignature)
        await transactionSyncService.recordBroadcast(identifier: identifier, account: account)
        return identifier
    }
}

// MARK: - Private helpers

// `makeSigner` is reused by `DappSigningService` for message signing, so it
// lives in its own `internal` extension rather than the `private extension`
// below (whose members default to `fileprivate`, and a `private extension`
// can't widen an individual member's access back to `internal`).
extension TransactionService {
    /// Constructs the appropriate ``Signer`` for `account` by looking up its
    /// keystore and deriving (or fetching from hardware) the private key.
    func makeSigner(for account: Account) async throws -> any Signer {
        try await makeSigner(for: account, keyStore: fetchKeyStore(for: account))
    }

    /// Runs `body` with `account`'s signer. For a hardware key store it runs
    /// inside a ``HardwareService`` session, so hardware key prompts stay up
    /// until it finishes. Use instead of ``makeSigner(for:)`` whenever the
    /// signer may touch a device.
    func withSigner<T>(for account: Account, _ body: (any Signer) async throws -> T) async throws -> T {
        let keyStore = try await fetchKeyStore(for: account)

        guard case .trezor = keyStore.kind else {
            return try await body(makeSigner(for: account, keyStore: keyStore))
        }

        return try await hardwareService.session {
            try await body(makeSigner(for: account, keyStore: keyStore))
        }
    }

    /// Runs `body` with `account`'s Cardano dapp signer (CIP-30). The key store
    /// is unlocked, or the hardware session started, only after
    /// `beforeKeyAccess` returns, so a dapp's approval can be re-validated
    /// immediately before key material is touched.
    func withCardanoDappSigner<T>(
        for account: Account,
        beforeKeyAccess: () async throws -> Void,
        _ body: (any CardanoDappSigner) async throws -> T
    ) async throws -> T {
        let keyStore = try await fetchKeyStore(for: account)

        guard let derivationPath = account.derivationPath, case let .cardano(network) = account.blockchain else {
            throw ReefrError.notSupported
        }

        switch keyStore.kind {
        case .local:
            try await beforeKeyAccess()
            let entropy = try await keyStore.localEntropy(reason: "Authenticate to sign with your key")
            return try await body(CardanoPKeySigner(entropy: entropy, network: network, path: derivationPath))
        case .trezor:
            guard let deviceId = keyStore.deviceId else {
                throw ReefrError.invalidData
            }

            let descriptor = try CardanoAccountDescriptor(string: account.address)

            return try await hardwareService.session {
                try await beforeKeyAccess()
                let device = try await hardwareService.connect(.trezor, deviceId: deviceId)
                let signer = try CardanoTrezorSigner(descriptor: descriptor, path: derivationPath, device: device)

                return try await body(signer)
            }

        case .watchOnly:
            throw ReefrError.notSupported
        }
    }

    /// Whether `account`'s key lives on a hardware wallet — answered from
    /// its key store, without connecting to the device.
    func isHardwareBacked(_ account: Account) async throws -> Bool {
        guard let keyStore = try await databaseService.fetchKeyStore(id: account.keyStoreId) else {
            throw ReefrError.notFound
        }

        if case .trezor = keyStore.kind {
            return true
        }

        return false
    }
}

private extension TransactionService {
    func fetchKeyStore(for account: Account) async throws -> KeyStore {
        guard let keyStore = try await databaseService.fetchKeyStore(id: account.keyStoreId) else {
            throw ReefrError.notFound
        }

        return keyStore
    }

    func makeSigner(for account: Account, keyStore: KeyStore) async throws -> any Signer {
        guard let derivationPath = account.derivationPath else {
            // Watch-only accounts cannot sign transactions.
            throw ReefrError.notSupported
        }

        switch keyStore.kind {
        case .local:
            let rawKey = try await keyStore.localSeed(reason: "Authenticate to sign with your key")
            return try makeLocalSigner(for: account, rawKey: rawKey, derivationPath: derivationPath)
        case .trezor:
            guard let deviceId = keyStore.deviceId else {
                throw ReefrError.invalidData
            }

            let device = try await hardwareService.connect(.trezor, deviceId: deviceId)
            return try await makeTrezorSigner(for: account, device: device, derivationPath: derivationPath)
        case .watchOnly:
            throw ReefrError.notSupported
        }
    }

    func signCardanoTransaction(_ request: Data, account: Account) async throws -> Data {
        let keyStore = try await fetchKeyStore(for: account)

        guard let derivationPath = account.derivationPath else {
            throw ReefrError.invalidData
        }

        switch keyStore.kind {
        case .local:
            let entropy = try await keyStore.localEntropy(reason: "Authenticate to sign with your key")
            let transaction = try JSONDecoder().decode(CardanoUnsignedTransaction.self, from: request)
            return try transaction.signed(entropy: entropy, path: derivationPath)
        case .trezor:
            guard let deviceId = keyStore.deviceId else {
                throw ReefrError.invalidData
            }

            guard case let .cardano(network) = account.blockchain else {
                throw ReefrError.invalidData
            }

            return try await hardwareService.session {
                let device = try await hardwareService.connect(.trezor, deviceId: deviceId)

                return try await CardanoTrezorSigner(network: network, path: derivationPath, device: device)
                    .sign(transaction: request)
            }

        case .watchOnly:
            throw ReefrError.notSupported
        }
    }

    /// Builds the ``BlockchainTransactionBuilderOptions`` array that conveys
    /// the user's fee overrides to the transaction builder.
    ///
    /// A field left empty is treated as "not overridden". A field that is
    /// non-empty but fails to parse is a user error and must fail loudly
    /// rather than silently falling back to freshly estimated fees.
    func buildOptions(_ fees: Fees, blockchain: Blockchain) throws -> [BlockchainTransactionBuilderOptions] {
        switch blockchain {
        case .aptos:
            let maxGasAmount = try parseUInt64Override(fees.aptosMaxGasAmount)
            let gasUnitPrice = try parseUInt64Override(fees.aptosGasUnitPrice)
            guard maxGasAmount != nil || gasUnitPrice != nil else {
                return []
            }

            return [.aptosGasOverride(maxGasAmount: maxGasAmount, gasUnitPrice: gasUnitPrice)]
        case .evm:
            let maxFee = try parseBigUIntOverride(fees.ethereumMaxFee)
            let maxPriority = try parseBigUIntOverride(fees.ethereumMaxPriorityFee)
            guard maxFee != nil || maxPriority != nil else {
                return []
            }

            return [.ethereumFeeOverride(maxFeePerGas: maxFee, maxPriorityFeePerGas: maxPriority, gasLimit: nil)]
        case .sui:
            let budget = try parseUInt64Override(fees.suiGasBudget)
            let price = try parseUInt64Override(fees.suiGasPrice)
            guard budget != nil || price != nil else {
                return []
            }

            return [.suiGasOverride(budget: budget, price: price)]
        case .bitcoin:
            guard let rate = try parseUInt64Override(fees.bitcoinFeeRate) else {
                return []
            }

            return [.bitcoinFeeOverride(feeRateSatPerVByte: rate)]
        case .tron:
            guard let limit = try parseUInt64Override(fees.tronFeeLimit) else {
                return []
            }

            return [.tronFeeLimit(limit)]
        case .solana:
            let price = try parseUInt64Override(fees.solanaPriorityFee)
            let limit = try parseUInt32Override(fees.solanaComputeUnitLimit)
            guard price != nil || limit != nil else {
                return []
            }

            return [.solanaPriorityFee(microLamportsPerComputeUnit: price, computeUnitLimit: limit)]
        default:
            return []
        }
    }

    /// Parses a user-supplied fee override string, throwing if it's present
    /// but not a valid value rather than silently dropping the override.
    func parseBigUIntOverride(_ text: String?) throws -> BigUInt? {
        guard let text, !text.isEmpty else {
            return nil
        }

        guard let value = BigUInt(text) else {
            throw ReefrError.invalidData
        }

        return value
    }

    /// Parses a user-supplied fee override string, throwing if it's present
    /// but not a valid value rather than silently dropping the override.
    func parseUInt64Override(_ text: String?) throws -> UInt64? {
        guard let text, !text.isEmpty else {
            return nil
        }

        guard let value = UInt64(text) else {
            throw ReefrError.invalidData
        }

        return value
    }

    /// Parses a user-supplied fee override string, throwing if it's present
    /// but not a valid value rather than silently dropping the override.
    func parseUInt32Override(_ text: String?) throws -> UInt32? {
        guard let text, !text.isEmpty else {
            return nil
        }

        guard let value = UInt32(text) else {
            throw ReefrError.invalidData
        }

        return value
    }

    private func makeLocalSigner(
        for account: Account,
        rawKey: Data,
        derivationPath: DerivationPath
    ) throws -> any Signer {
        let seed = try Seed(rawBytes: rawKey)

        switch account.blockchain {
        case .aptos, .sui:
            return try makeChoosableCurveSigner(for: account, seed: seed, derivationPath: derivationPath)

        case let .evm(chain):
            let privateKey = try seed
                .masterKey(curve: .secp256k1)
                .derive(derivationPath)
                .privateKey()

            return try EthereumPKeySigner(
                chainId: chain.chainId,
                privateKey: privateKey,
                derivationPath: derivationPath
            )

        case let .bitcoin(network):
            let descriptor = try BitcoinDescriptor(string: account.address, network: network)
            return try BitcoinPKeySigner(descriptor: descriptor, seed: seed, derivationPath: derivationPath)

        case let .tron(network):
            let privateKey = try seed
                .masterKey(curve: .secp256k1)
                .derive(derivationPath)
                .privateKey()

            return try TronPKeySigner(
                network: network,
                privateKey: privateKey,
                derivationPath: derivationPath
            )

        case let .solana(network):
            let privateKey = try seed
                .masterKey(curve: .ed25519)
                .derive(derivationPath)
                .privateKey()

            return try SolanaPKeySigner(
                network: network,
                privateKey: privateKey,
                derivationPath: derivationPath
            )

        case .cardano:
            // Cardano local signing is handled directly in
            // `signCardanoTransaction`, which signs before a `Signer` is
            // constructed here.
            throw ReefrError.notImplemented
        }
    }

    /// Signers for chains whose accounts pick Ed25519 or secp256k1
    /// (`Account.signatureScheme`, Ed25519 by default).
    private func makeChoosableCurveSigner(
        for account: Account,
        seed: Seed,
        derivationPath: DerivationPath
    ) throws -> any Signer {
        let curve = account.signatureScheme ?? .ed25519
        let privateKey = try seed.masterKey(curve: curve).derive(derivationPath).privateKey()

        switch account.blockchain {
        case let .aptos(network):
            return try AptosPKeySigner(
                curve: curve,
                network: network,
                privateKey: privateKey,
                derivationPath: derivationPath
            )

        case let .sui(network):
            return try SuiPKeySigner(
                curve: curve,
                network: network,
                privateKey: privateKey,
                derivationPath: derivationPath
            )

        default:
            throw ReefrError.invalidData
        }
    }

    private func makeTrezorSigner(
        for account: Account,
        device: HardwareDevice,
        derivationPath: DerivationPath
    ) async throws -> any Signer {
        switch account.blockchain {
        case let .evm(chain):
            return try await EthereumTrezorSigner(
                chainId: chain.chainId, device: device, derivationPath: derivationPath
            )

        case let .bitcoin(network):
            let descriptor = try BitcoinDescriptor(string: account.address, network: network)
            return try await BitcoinTrezorSigner(
                network: network,
                scriptType: descriptor.scriptType,
                path: derivationPath,
                device: device
            )

        case let .tron(network):
            return try await TronTrezorSigner(
                network: network,
                device: device,
                derivationPath: derivationPath
            )

        case let .solana(network):
            return try await SolanaTrezorSigner(
                network: network,
                device: device,
                derivationPath: derivationPath
            )

        default:
            throw ReefrError.notImplemented
        }
    }
}
