//
//  FeeEstimationService.swift
//  Reefr Wallet
//
//  Created by Andrey Yurkevich on 22.09.26.
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import BigInt
import Foundation
import WalletKit

// MARK: - FeeEstimationService

final class FeeEstimationService {
    private lazy var clientProvider = DI.injectOrFail(BlockchainClientProvider.self)

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

        let amount = try token.smallestUnitAmount(from: decimalAmount)

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
}

// MARK: - Private helpers

private extension FeeEstimationService {
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
            ethereumMaxFee: maxFee.description,
            ethereumMaxPriorityFee: priorityFee.description,
            nativeFeeReserve: token.isNativeToken ? feeEstimate.estimatedFee?.description : nil
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
            nativeFeeReserve: token.isNativeToken ? feeEstimate.estimatedFee?.description : nil,
            solanaComputeUnitLimit: feeEstimate.gasLimit?.description,
            solanaPriorityFee: feeEstimate.gasPrice.description
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
            nativeFeeReserve: token.isNativeToken ? grossFee.description : nil,
            suiGasBudget: grossFee.description,
            suiGasPrice: feeEstimate.gasPrice.description
        )
    }
}
