//
//  FeeEstimationService.swift
//  Reefr Wallet
//
//  Created by Andrey Yurkevich on 22.09.26.
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import WalletKit

// MARK: - FeeEstimationService

/// `@unchecked Sendable`: a DI-injected singleton, called from concurrent
/// contexts already (like every other service in `Sources/Services`); needed
/// here only because ``EthereumDappProvider`` (`Sendable`) stores one.
final class FeeEstimationService: @unchecked Sendable {
    private lazy var clientProvider = DI.injectOrFail(BlockchainClientProvider.self)

    /// Estimates network fees for a transfer of `token` from `account` to
    /// `recipient`, using each chain's own fee API.
    func estimateFees(
        token: Token,
        decimalAmount: String,
        cardanoRecipientLovelace: String? = nil,
        recipient: String,
        account: Account
    ) async throws -> Fees {
        let amount = try token.smallestUnitAmount(from: decimalAmount)

        switch account.blockchain {
        case .aptos:
            return try await estimateAptosFees(token: token, amount: amount, recipient: recipient, account: account)

        case .bitcoin:
            return try await estimateBitcoinFees(amount: amount, recipient: recipient, account: account)

        case .cardano:
            return try await estimateCardanoFees(
                token: token,
                amount: amount,
                recipientLovelace: cardanoRecipientLovelace,
                recipient: recipient,
                account: account
            )

        case .evm:
            return try await estimateEthereumFees(token: token, amount: amount, recipient: recipient, account: account)

        case .solana:
            return try await estimateSolanaFees(token: token, amount: amount, recipient: recipient, account: account)

        case .sui:
            return try await estimateSuiFees(token: token, amount: amount, recipient: recipient, account: account)

        case .tron:
            return Fees(tronFeeLimit: token.isNativeToken ? nil : "100000000")
        }
    }

    /// Estimates network fees for an arbitrary Ethereum call — a dapp's
    /// `eth_sendTransaction`.
    ///
    /// - Parameter to: The call destination, or `nil` for contract creation.
    func estimateFees(
        to: EthereumAddress?,
        value: BigUInt,
        data: Data,
        account: Account
    ) async throws -> Fees {
        let estimate = try await estimateCall(to: to, value: value, data: data, gasLimit: nil, account: account)
        return ethereumFees(rates: estimate.rates, gasLimit: estimate.gasLimit)
    }

    /// Gas limit and fee rates for an arbitrary Ethereum call. Skips
    /// `eth_estimateGas` when `gasLimit` is given.
    func estimateCall(
        to: EthereumAddress?,
        value: BigUInt,
        data: Data,
        gasLimit: BigUInt?,
        account: Account
    ) async throws -> (gasLimit: BigUInt, rates: EthereumFeeRates) {
        let client = try clientProvider.ethereumClient(for: account)
        let sender = try EthereumAddress(string: account.address)

        async let rates = client.feeRates()
        let resolvedGasLimit: BigUInt
        if let gasLimit {
            resolvedGasLimit = gasLimit
        } else {
            resolvedGasLimit = try await client.estimateGas(from: sender, to: to, value: value, data: data)
        }

        return (resolvedGasLimit, try await rates)
    }

    /// Ethereum ``Fees`` for `gasLimit` at the given caps; the displayed
    /// base fee comes from `rates`.
    func ethereumFees(
        rates: EthereumFeeRates,
        gasLimit: BigUInt,
        maxFee: BigUInt,
        maxPriorityFee: BigUInt
    ) -> Fees {
        let baseFee = rates.maxFeePerGas > rates.maxPriorityFeePerGas
            ? (rates.maxFeePerGas - rates.maxPriorityFeePerGas) / 2
            : BigUInt(0)

        return Fees(
            ethereumBaseFee: baseFee.description,
            ethereumMaxFee: maxFee.description,
            ethereumMaxPriorityFee: maxPriorityFee.description,
            nativeFeeReserve: (gasLimit * maxFee).description
        )
    }
}

// MARK: - Private helpers

private extension FeeEstimationService {
    /// Builds (and so simulates) the transfer, then reads back the gas the
    /// builder chose. The reserve is `max_gas × price`: the balance the node
    /// requires up front, so a max-amount send still passes validation.
    func estimateAptosFees(token: Token, amount: BigUInt, recipient: String, account: Account) async throws -> Fees {
        let client = try clientProvider.aptosClient(for: account)
        let transaction = try await AptosTransactionBuilder(client: client).buildTransfer(
            sender: account.address,
            recipient: recipient,
            amount: amount,
            token: token.isNativeToken ? nil : token.address
        )

        let gas = try AptosRawTransaction.gasParameters(of: transaction)

        return Fees(
            aptosGasUnitPrice: String(gas.gasUnitPrice),
            aptosMaxGasAmount: String(gas.maxGasAmount),
            nativeFeeReserve: token.isNativeToken ? String(try AptosRawTransaction.maxFee(of: transaction)) : nil
        )
    }

    /// Builds the unsigned PSBT (which runs coin selection at the current
    /// fee rate) and reads back its implied fee.
    func estimateBitcoinFees(amount: BigUInt, recipient: String, account: Account) async throws -> Fees {
        let client = try clientProvider.bitcoinClient(for: account)
        let builder = BitcoinTransactionBuilder(client: client)

        async let feeRate = client.feeRate()

        let psbt = try await builder.buildTransfer(
            sender: account.address,
            recipient: recipient,
            amount: amount,
            token: nil
        )

        return Fees(
            bitcoinFeeRate: String(try await feeRate),
            nativeFeeReserve: String(try client.fee(psbt: psbt))
        )
    }

    func estimateCardanoFees(
        token: Token,
        amount: BigUInt,
        recipientLovelace: String?,
        recipient: String,
        account: Account
    ) async throws -> Fees {
        let builder = try clientProvider.makeTransactionBuilder(
            blockchain: account.blockchain,
            rpcURL: account.rpcURLOverride
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

    /// Runs `eth_estimateGas` against the actual call: a plain value
    /// transfer for native ETH, or ERC-20 `transfer(address,uint256)`.
    func estimateEthereumFees(token: Token, amount: BigUInt, recipient: String, account: Account) async throws -> Fees {
        let recipientAddress = try EthereumAddress(string: recipient)

        guard !token.isNativeToken else {
            return try await estimateFees(to: recipientAddress, value: amount, data: Data(), account: account)
        }

        guard let tokenAddress = token.address else {
            throw Error.invalidData
        }

        let calldata = EthereumABI.encodeCall(
            selector: EthereumABI.selector("transfer(address,uint256)"),
            parameters: [.address(recipientAddress), .uint256(amount)]
        )

        let fees = try await estimateFees(
            to: EthereumAddress(string: tokenAddress), value: 0, data: calldata, account: account
        )

        return Fees(
            ethereumBaseFee: fees.ethereumBaseFee,
            ethereumMaxFee: fees.ethereumMaxFee,
            ethereumMaxPriorityFee: fees.ethereumMaxPriorityFee
        )
    }

    func ethereumFees(rates: EthereumFeeRates, gasLimit: BigUInt) -> Fees {
        ethereumFees(
            rates: rates,
            gasLimit: gasLimit,
            maxFee: rates.maxFeePerGas,
            maxPriorityFee: rates.maxPriorityFeePerGas
        )
    }

    /// Builds the unsigned envelope (with the default priority fee) and
    /// prices its message.
    func estimateSolanaFees(token: Token, amount: BigUInt, recipient: String, account: Account) async throws -> Fees {
        let client = try clientProvider.solanaClient(for: account)

        let envelope = try await SolanaTransactionBuilder(client: client).buildTransfer(
            sender: account.address,
            recipient: recipient,
            amount: amount,
            token: token.isNativeToken ? nil : token.address
        )

        let estimate = try await client.estimateFee(transaction: envelope)

        return Fees(
            nativeFeeReserve: token.isNativeToken ? String(estimate.fee) : nil,
            solanaComputeUnitLimit: estimate.computeUnitLimit.map(String.init),
            solanaPriorityFee: String(estimate.computeUnitPrice)
        )
    }

    /// Builds unsigned BCS bytes for the transfer then simulates them to
    /// produce `suiGasBudget` and `suiGasPrice`.
    func estimateSuiFees(token: Token, amount: BigUInt, recipient: String, account: Account) async throws -> Fees {
        let client = try clientProvider.suiClient(for: account)

        async let gasPrice = client.referenceGasPrice()
        let bcs = try await SuiTransactionBuilder(client: client).buildTransfer(
            sender: account.address,
            recipient: recipient,
            amount: amount,
            token: token.isNativeToken ? nil : token.address
        )

        let grossCost = String(try await client.gasCostSummary(transactionData: bcs).grossCost)

        return Fees(
            nativeFeeReserve: token.isNativeToken ? grossCost : nil,
            suiGasBudget: grossCost,
            suiGasPrice: String(try await gasPrice)
        )
    }
}
