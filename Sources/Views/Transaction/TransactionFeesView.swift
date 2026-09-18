//
//  TransactionFeesView.swift
//  Reefr Wallet
//
//  Created by Andrey Yurkevich on 15.09.26.
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import BigInt
import SwiftUI
import WalletKit

// MARK: - TransactionFeesView

struct TransactionFeesView {
    let blockchain: WKBlockchain
    /// Fees fetched from the network, pushed into the editable fields whenever it
    /// changes. `nil` clears them, which is what keeps "Next" disabled while a
    /// fresh estimate is in flight.
    let estimatedFees: Fees?

    @Binding var fees: Fees?

    @State private var ethereumBaseFee = ""
    @State private var ethereumMaxFee = ""
    @State private var ethereumMaxPriorityFee = ""
    @State private var nativeTokenPriceUSD: Decimal?
    @State private var suiGasBudget = ""
    @State private var suiGasPrice = ""
}

// MARK: - View

extension TransactionFeesView: View {
    @ViewBuilder
    var body: some View {
        Section {
            switch blockchain {
            case .evm:
                evmFeesForm
            case .sui:
                suiFeesForm
            default:
                EmptyView()
            }
        }
        .onChange(of: estimatedFees, initial: true) { _, newValue in
            apply(newValue)
        }
        .onChange(of: validatedFees, initial: true) { _, newValue in
            fees = newValue
        }
        .task {
            await loadNativeTokenPrice()
        }
    }
}

// MARK: - Subviews

private extension TransactionFeesView {
    @ViewBuilder
    var evmFeesForm: some View {
        LabeledContent {
            TextField("", text: $ethereumBaseFee)
                .frame(height: 28)
                .disabled(true)
        } label: {
            Text("Base fee")
                .style(.small, foreground: .secondary)
        }

        LabeledContent {
            TextField("", text: $ethereumMaxPriorityFee)
                .frame(height: 28)
        } label: {
            Text("Max priority fee per gas")
                .style(.small, foreground: .secondary)
        }

        LabeledContent {
            TextField("", text: $ethereumMaxFee)
                .frame(height: 28)
        } label: {
            Text("Max fee per gas")
                .style(.small, foreground: .secondary)
        }

        LabeledContent {
            TextField("", text: transactionCost)
                .frame(height: 28)
                .disabled(true)
        } label: {
            Text("Transaction cost (USD)")
                .style(.small, foreground: .secondary)
        }
    }

    @ViewBuilder
    var suiFeesForm: some View {
        LabeledContent {
            TextField("", text: $suiGasPrice)
                .disabled(true)
        } label: {
            Text("Gas price (MIST)")
                .style(.small, foreground: .secondary)
        }

        LabeledContent {
            TextField("", text: $suiGasBudget)
        } label: {
            Text("Gas budget")
                .style(.small, foreground: .secondary)
        }

        LabeledContent {
            TextField("", text: transactionCost)
                .frame(height: 28)
                .disabled(true)
        } label: {
            Text("Transaction cost (USD)")
                .style(.small, foreground: .secondary)
        }
    }
}

// MARK: - Logic

private extension TransactionFeesView {
    func apply(_ estimate: Fees?) {
        ethereumBaseFee = estimate?.ethereumBaseFee ?? ""
        ethereumMaxPriorityFee = estimate?.ethereumMaxPriorityFee ?? ""
        ethereumMaxFee = estimate?.ethereumMaxFee ?? ""
        suiGasBudget = estimate?.suiGasBudget ?? ""
        suiGasPrice = estimate?.suiGasPrice ?? ""
    }

    /// Fetches the native token's USD price via the blockchain's WalletKit
    /// client, used to convert `estimatedFees.nativeFeeReserve` into a USD cost.
    func loadNativeTokenPrice() async {
        do {
            let client = try await DI.injectOrFail(BlockchainClientProvider.self).getClient(blockchain: blockchain)
            nativeTokenPriceUSD = try await client.getTokenPrice(nil)
        } catch {
            printError(error)
            nativeTokenPriceUSD = nil
        }
    }

    /// Total network fee, converted from the chain's smallest unit into a
    /// formatted USD string. Empty when the estimate or price isn't available
    /// yet (e.g. Sui pricing isn't implemented in WalletKit).
    var transactionCost: Binding<String> {
        guard
            let nativeFeeReserve = estimatedFees?.nativeFeeReserve,
            let feeAmount = BigUInt(nativeFeeReserve),
            let nativeTokenPriceUSD
        else {
            return .constant("")
        }

        let decimalFee = Decimal(
            sign: .plus,
            exponent: -Int(blockchain.nativeToken.decimals),
            significand: Decimal(feeAmount)
        )

        let cost = decimalFee * nativeTokenPriceUSD
        return .constant(cost.formatted(.currency(code: "USD")))
    }

    var validatedFees: Fees? {
        switch blockchain {
        case .evm:
            guard BigUInt(ethereumMaxPriorityFee) != nil, BigUInt(ethereumMaxFee) != nil else {
                return nil
            }

            return Fees(
                ethereumBaseFee: ethereumBaseFee,
                ethereumMaxPriorityFee: ethereumMaxPriorityFee,
                ethereumMaxFee: ethereumMaxFee
            )
        case .sui:
            guard UInt64(suiGasBudget) != nil, UInt64(suiGasPrice) != nil else {
                return nil
            }

            return Fees(suiGasBudget: suiGasBudget, suiGasPrice: suiGasPrice)
        default:
            return nil
        }
    }
}
