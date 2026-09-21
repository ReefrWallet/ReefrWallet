//
//  TransactionService.swift
//  Reefr Wallet
//
//  Created by Andrey Yurkevich on 26.02.26.
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import BigInt
import Foundation
import WalletKit

// MARK: - TransactionService

final class TransactionService {
    private lazy var clientProvider = DI.injectOrFail(BlockchainClientProvider.self)
    private lazy var hardwareService = DI.injectOrFail(HardwareService.self)
    private lazy var transactionSyncService = DI.injectOrFail(TransactionSyncService.self)
    private let databaseService: DatabaseService

    init(databaseService: DatabaseService? = nil) {
        self.databaseService = databaseService ?? DI.injectOrFail(DatabaseService.self)
    }

    /// Estimates network fees for a transfer of `token` from `account` to
    /// `recipient`.
    ///
    /// - For EVM: fetches current EIP-1559 fee rates and runs
    ///   `eth_estimateGas` against the actual call (a plain value transfer
    ///   for native ETH, or the ABI-encoded `transfer(address,uint256)`
    ///   calldata for an ERC-20) to populate `ethereumBaseFee`.
    /// - For Sui: builds unsigned BCS bytes for the transfer then simulates
    ///   them to produce `suiGasBudget` and `suiGasPrice`.
    func estimateFees( // swiftlint:disable:this function_body_length
        token: Token,
        decimalAmount: String,
        cardanoRecipientLovelace: String? = nil,
        recipient: String,
        account: Account
    ) async throws -> Fees {
        let blockchain = account.blockchain

        let client = try await clientProvider.getClient(
            blockchain: blockchain, rpcURL: account.rpcURLOverride, backend: account.bitcoinBackend
        )

        let amount = try makeAmount(decimalAmount, token: token)

        switch blockchain {
        case .evm:
            return try await estimateEthereumFees(
                client: client,
                token: token,
                amount: amount,
                recipient: recipient,
                account: account
            )
        case .sui:
            return try await estimateSuiFees(
                client: client,
                blockchain: blockchain,
                token: token,
                amount: amount,
                recipient: recipient,
                account: account
            )
        case .bitcoin:
            return try await estimateBitcoinFees(
                client: client,
                blockchain: blockchain,
                amount: amount,
                recipient: recipient,
                account: account
            )
        case .cardano:
            return try await estimateCardanoFees(
                blockchain: blockchain,
                token: token,
                amount: amount,
                recipientLovelace: cardanoRecipientLovelace,
                recipient: recipient,
                account: account
            )
        case .tron:
            return Fees(tronFeeLimit: token.isNativeToken ? nil : "100000000")
        case .solana:
            return try await estimateSolanaFees(
                client: client,
                blockchain: blockchain,
                token: token,
                amount: amount,
                recipient: recipient,
                account: account
            )
        }
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
            throw Error.invalidData
        }

        let amount = try makeAmount(decimalAmount, token: token)
        // nil token identifier → native asset; non-nil → ERC-20 / Sui coin type.
        let tokenId: String? = token.isNativeToken ? nil : token.address
        var options = try fees.map { try buildOptions($0, blockchain: blockchain) } ?? []
        if case .cardano = blockchain, !token.isNativeToken {
            guard let cardanoRecipientLovelace, let lovelace = UInt64(cardanoRecipientLovelace) else {
                throw Error.invalidData
            }
            options.append(.cardanoRecipientLovelace(lovelace))
        }

        let builder = try await clientProvider.getBuilder(
            blockchain: blockchain, rpcURL: account.rpcURLOverride, backend: account.bitcoinBackend
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
            return try await signCardanoTransaction(txRequest, account: account)
        }

        let signer = try await makeSigner(for: account)
        return try await signer.sign(transaction: txRequest)
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
        let client = try await clientProvider.getClient(
            blockchain: account.blockchain, rpcURL: account.rpcURLOverride, backend: account.bitcoinBackend
        )
        let identifier = try await client.broadcast(transaction: txRequest, signature: txSignature)
        await transactionSyncService.recordBroadcast(identifier: identifier, account: account)
        return identifier
    }
}

// MARK: - Private helpers

private extension TransactionService {
    func estimateCardanoFees(
        blockchain: WKBlockchain,
        token: Token,
        amount: BigUInt,
        recipientLovelace: String?,
        recipient: String,
        account: Account
    ) async throws -> Fees {
        let builder = try await clientProvider.getBuilder(
            blockchain: blockchain,
            rpcURL: account.rpcURLOverride,
            backend: account.bitcoinBackend
        )
        var options: [BlockchainTransactionBuilderOptions] = []
        if !token.isNativeToken {
            guard let recipientLovelace, let lovelace = UInt64(recipientLovelace) else {
                throw Error.invalidData
            }
            options.append(.cardanoRecipientLovelace(lovelace))
        }
        let transaction = try await builder.buildTransfer(
            sender: account.address,
            recipient: recipient,
            amount: amount,
            token: token.isNativeToken ? nil : token.address,
            options: options
        )
        let unsigned = try JSONDecoder().decode(CardanoUnsignedTransaction.self, from: transaction)
        return Fees(cardanoRecipientLovelace: recipientLovelace, nativeFeeReserve: unsigned.fee)
    }

    func signCardanoTransaction(_ request: Data, account: Account) async throws -> Data {
        guard let keyStore = try await databaseService.fetchKeyStore(id: account.keyStoreId) else {
            throw Error.notFound
        }
        guard let rawAccountIndex = account.accountIndex, let accountIndex = UInt32(exactly: rawAccountIndex) else {
            throw Error.invalidData
        }
        switch keyStore.kind {
        case .local:
            guard let entropy = keyStore.mnemonicEntropy else {
                throw Error.invalidData
            }
            let transaction = try JSONDecoder().decode(CardanoUnsignedTransaction.self, from: request)
            return try transaction.signed(entropy: entropy, accountIndex: accountIndex)
        case .trezor:
            guard let deviceId = keyStore.deviceId else {
                throw Error.invalidData
            }
            guard case let .cardano(network) = account.blockchain else {
                throw Error.invalidData
            }
            let device = try await hardwareService.connect(.trezor, deviceId: deviceId)
            return try await CardanoTrezorSigner(network: network, accountIndex: accountIndex, device: device)
                .sign(transaction: request)
        case .watchOnly:
            throw Error.notSupported
        }
    }

    /// Fetches EIP-1559 fee rates and runs `eth_estimateGas` against the
    /// actual call (a plain value transfer for native ETH, or the
    /// ABI-encoded `transfer(address,uint256)` calldata for an ERC-20) to
    /// populate `ethereumBaseFee`.
    func estimateEthereumFees(
        client: AnyBlockchainClient,
        token: Token,
        amount: BigUInt,
        recipient: String,
        account: Account
    ) async throws -> Fees {
        let feeEstimate: FeeEstimate
        if token.isNativeToken {
            let request = AnyFeeEstimateRequest(
                from: account.address,
                to: recipient,
                value: amount
            )
            feeEstimate = try await client.estimateFee(for: request)
        } else {
            // Build the real ERC-20 transfer calldata so `eth_estimateGas`
            // sees the exact call — gas usage varies per token contract
            // and can't be approximated from rates alone.
            guard let tokenAddress = token.address else {
                throw Error.invalidData
            }

            let contract = try EthereumAddress(string: tokenAddress)
            let recipientAddress = try EthereumAddress(string: recipient)

            let calldata = EthereumABI.encodeCall(
                selector: EthereumABI.selector("transfer(address,uint256)"),
                parameters: [.address(recipientAddress), .uint256(amount)]
            )

            let request = AnyFeeEstimateRequest(
                from: account.address,
                to: contract.string,
                data: calldata
            )

            feeEstimate = try await client.estimateFee(for: request)
        }

        let maxFee = feeEstimate.maxFeePerGas ?? feeEstimate.gasPrice
        let priorityFee = feeEstimate.maxPriorityFeePerGas ?? BigUInt(0)
        let baseFee = maxFee > priorityFee ? (maxFee - priorityFee) / 2 : BigUInt(0)

        return Fees(
            ethereumBaseFee: baseFee.description,
            ethereumMaxPriorityFee: priorityFee.description,
            ethereumMaxFee: maxFee.description,
            nativeFeeReserve: token.isNativeToken ? feeEstimate.estimatedFee?.description : nil
        )
    }

    /// Builds unsigned BCS bytes for the transfer then simulates them to
    /// produce `suiGasBudget` and `suiGasPrice`.
    func estimateSuiFees(
        client: AnyBlockchainClient,
        blockchain: WKBlockchain,
        token: Token,
        amount: BigUInt,
        recipient: String,
        account: Account
    ) async throws -> Fees {
        // Build the unsigned transaction to get a realistic simulation.
        let builder = try await clientProvider.getBuilder(blockchain: blockchain, rpcURL: account.rpcURLOverride)
        let bcs = try await builder.buildTransfer(
            sender: account.address,
            recipient: recipient,
            amount: amount,
            token: token.isNativeToken ? nil : token.address
        )
        let request = AnyFeeEstimateRequest(data: bcs)
        let feeEstimate = try await client.estimateFee(for: request)

        let grossFee = feeEstimate.grossFee ?? feeEstimate.estimatedFee ?? feeEstimate.gasPrice
        return Fees(
            suiGasBudget: grossFee.description,
            suiGasPrice: feeEstimate.gasPrice.description,
            nativeFeeReserve: token.isNativeToken ? grossFee.description : nil
        )
    }

    /// Builds the unsigned transaction envelope for the transfer (which
    /// already applies the default priority fee) then reads back its
    /// implied cost via ``BlockchainClientProtocol/estimateFee(for:)``'s
    /// message-aware path.
    func estimateSolanaFees(
        client: AnyBlockchainClient,
        blockchain: WKBlockchain,
        token: Token,
        amount: BigUInt,
        recipient: String,
        account: Account
    ) async throws -> Fees {
        let builder = try await clientProvider.getBuilder(blockchain: blockchain, rpcURL: account.rpcURLOverride)
        let envelope = try await builder.buildTransfer(
            sender: account.address,
            recipient: recipient,
            amount: amount,
            token: token.isNativeToken ? nil : token.address
        )
        let request = AnyFeeEstimateRequest(data: envelope)
        let feeEstimate = try await client.estimateFee(for: request)

        return Fees(
            solanaPriorityFee: feeEstimate.gasPrice.description,
            solanaComputeUnitLimit: feeEstimate.gasLimit?.description,
            nativeFeeReserve: token.isNativeToken ? feeEstimate.estimatedFee?.description : nil
        )
    }

    /// Builds the unsigned PSBT for the transfer (which already runs real
    /// coin selection at the current fee rate) then reads back its
    /// implied fee via ``BlockchainClientProtocol/estimateFee(for:)``'s
    /// PSBT-aware path.
    func estimateBitcoinFees(
        client: AnyBlockchainClient,
        blockchain: WKBlockchain,
        amount: BigUInt,
        recipient: String,
        account: Account
    ) async throws -> Fees {
        let builder = try await clientProvider.getBuilder(
            blockchain: blockchain, rpcURL: account.rpcURLOverride, backend: account.bitcoinBackend
        )
        let psbt = try await builder.buildTransfer(
            sender: account.address, recipient: recipient, amount: amount, token: nil
        )
        let request = AnyFeeEstimateRequest(data: psbt)
        let feeEstimate = try await client.estimateFee(for: request)

        return Fees(
            bitcoinFeeRate: feeEstimate.gasPrice.description,
            nativeFeeReserve: feeEstimate.estimatedFee?.description
        )
    }

    /// Builds the ``BlockchainTransactionBuilderOptions`` array that conveys
    /// the user's fee overrides to the transaction builder.
    ///
    /// A field left empty is treated as "not overridden". A field that is
    /// non-empty but fails to parse is a user error and must fail loudly
    /// rather than silently falling back to freshly estimated fees.
    func buildOptions(_ fees: Fees, blockchain: WKBlockchain) throws -> [BlockchainTransactionBuilderOptions] {
        switch blockchain {
        case .evm:
            let maxFee = try parseBigUIntOverride(fees.ethereumMaxFee)
            let maxPriority = try parseBigUIntOverride(fees.ethereumMaxPriorityFee)
            guard maxFee != nil || maxPriority != nil else { return [] }
            return [.ethereumFeeOverride(maxFeePerGas: maxFee, maxPriorityFeePerGas: maxPriority, gasLimit: nil)]
        case .sui:
            let budget = try parseUInt64Override(fees.suiGasBudget)
            let price = try parseUInt64Override(fees.suiGasPrice)
            guard budget != nil || price != nil else { return [] }
            return [.suiGasOverride(budget: budget, price: price)]
        case .bitcoin:
            guard let rate = try parseUInt64Override(fees.bitcoinFeeRate) else { return [] }
            return [.bitcoinFeeOverride(feeRateSatPerVByte: rate)]
        case .tron:
            guard let limit = try parseUInt64Override(fees.tronFeeLimit) else { return [] }
            return [.tronFeeLimit(limit)]
        case .solana:
            let price = try parseUInt64Override(fees.solanaPriorityFee)
            let limit = try parseUInt32Override(fees.solanaComputeUnitLimit)
            guard price != nil || limit != nil else { return [] }
            return [.solanaPriorityFee(microLamportsPerComputeUnit: price, computeUnitLimit: limit)]
        default:
            return []
        }
    }

    /// Parses a user-supplied fee override string, throwing if it's present
    /// but not a valid value rather than silently dropping the override.
    func parseBigUIntOverride(_ text: String?) throws -> BigUInt? {
        guard let text, !text.isEmpty else { return nil }
        guard let value = BigUInt(text) else { throw Error.invalidData }
        return value
    }

    /// Parses a user-supplied fee override string, throwing if it's present
    /// but not a valid value rather than silently dropping the override.
    func parseUInt64Override(_ text: String?) throws -> UInt64? {
        guard let text, !text.isEmpty else { return nil }
        guard let value = UInt64(text) else { throw Error.invalidData }
        return value
    }

    /// Parses a user-supplied fee override string, throwing if it's present
    /// but not a valid value rather than silently dropping the override.
    func parseUInt32Override(_ text: String?) throws -> UInt32? {
        guard let text, !text.isEmpty else { return nil }
        guard let value = UInt32(text) else { throw Error.invalidData }
        return value
    }

    /// Converts a human-readable decimal amount string to the chain's
    /// smallest unit as a `BigUInt`.
    ///
    /// Example: `"1.5"` with `decimalsCount = 6` → `BigUInt(1_500_000)`.
    func makeAmount(_ text: String, token: Token) throws -> BigUInt {
        guard let decimal = Decimal(string: text), decimal > 0 else {
            throw Error.invalidData
        }

        // Scale by 10^decimals without losing integer precision.
        var multiplier = Decimal(1)
        for _ in 0..<token.decimalsCount { multiplier *= 10 }
        let scaled = NSDecimalNumber(decimal: decimal * multiplier)
        let handler = NSDecimalNumberHandler(
            roundingMode: .down,
            scale: 0,
            raiseOnExactness: false,
            raiseOnOverflow: false,
            raiseOnUnderflow: false,
            raiseOnDivideByZero: false
        )
        let truncated = scaled.rounding(accordingToBehavior: handler)

        // Reject sub-smallest-unit amounts: the scaled value must already be an
        // exact integer. e.g. 0.0000001 USDC (6 decimals) → 0.1 base units → reject.
        guard scaled == truncated else {
            throw Error.invalidData
        }

        guard let amount = BigUInt(truncated.stringValue), amount > 0 else {
            throw Error.invalidData
        }
        return amount
    }

    /// Constructs the appropriate ``Signer`` for `account` by looking up its
    /// keystore and deriving (or fetching from hardware) the private key.
    func makeSigner(for account: Account) async throws -> any Signer {
        guard let keyStore = try await databaseService.fetchKeyStore(id: account.keyStoreId) else {
            throw Error.notFound
        }

        guard let derivationPathString = account.derivationPath else {
            // Watch-only accounts cannot sign transactions.
            throw Error.notSupported
        }

        let derivationPath = try DerivationPath(string: derivationPathString)

        switch keyStore.kind {
        case .local:
            let rawKey = try keyStore.localSeed()
            return try makeLocalSigner(for: account, rawKey: rawKey, derivationPath: derivationPath)
        case .trezor:
            guard let deviceId = keyStore.deviceId else { throw Error.invalidData }
            let device = try await hardwareService.connect(.trezor, deviceId: deviceId)
            return try await makeTrezorSigner(for: account, device: device, derivationPath: derivationPath)
        case .watchOnly:
            throw Error.notSupported
        }
    }

    private func makeLocalSigner(
        for account: Account,
        rawKey: Data,
        derivationPath: DerivationPath
    ) throws -> any Signer {
        let seed = try Seed(rawBytes: rawKey)

        switch account.blockchain {
        case let .evm(chain):
            let privateKey = try seed.masterKey(curve: .secp256k1).derive(derivationPath).privateKey()
            return try EthereumPKeySigner(
                chainId: chain.chainId, privateKey: privateKey, derivationPath: derivationPath
            )
        case let .sui(network):
            let curve = account.signatureScheme ?? .ed25519
            let privateKey = try seed.masterKey(curve: curve).derive(derivationPath).privateKey()
            return try SuiPKeySigner(
                curve: curve, network: network, privateKey: privateKey, derivationPath: derivationPath
            )
        case let .bitcoin(network):
            let descriptor = try BitcoinDescriptor(string: account.address, network: network)
            return try BitcoinPKeySigner(descriptor: descriptor, seed: seed, derivationPath: derivationPath)
        case let .tron(network):
            let privateKey = try seed.masterKey(curve: .secp256k1).derive(derivationPath).privateKey()
            return try TronPKeySigner(network: network, privateKey: privateKey, derivationPath: derivationPath)
        case let .solana(network):
            let privateKey = try seed.masterKey(curve: .ed25519).derive(derivationPath).privateKey()
            return try SolanaPKeySigner(network: network, privateKey: privateKey, derivationPath: derivationPath)
        default:
            throw Error.notImplemented
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
                accountIndex: UInt32(truncatingIfNeeded: account.accountIndex ?? 0),
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
            throw Error.notImplemented
        }
    }
}
