//
//  TransactionFeesView.swift
//  Reefr Wallet
//
//  Created by Andrey Yurkevich on 15.09.26.
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import SwiftUI
import WalletKit

// MARK: - TransactionFeesView

/// The "<Chain> Fees" section of ``TransactionSheet``, per the Penpot `Fees` component.
struct TransactionFeesView {
    let blockchain: Blockchain
    /// Fees fetched from the network, pushed into the editable fields whenever it
    /// changes. `nil` clears them, which is what keeps "Next" disabled while a
    /// fresh estimate is in flight.
    let estimatedFees: Fees?
    /// `false` shows every value as text; `fees` then mirrors `estimatedFees`.
    var isEditable = true
    /// `false` for TRX transfers, which don't call a contract and so have no fee limit.
    var isTronFeeLimitEnabled = true
    /// Not in Penpot: a caution note under the section, e.g. dapp-set fees.
    var warning: String?

    @Binding var fees: Fees?

    @State private var aptosGasUnitPrice = ""
    @State private var aptosMaxGasAmount = ""
    @State private var bitcoinFeeRate = ""
    /// Gwei, as edited; `Fees` carries wei.
    @State private var ethereumMaxFee = ""
    /// Gwei, as edited; `Fees` carries wei.
    @State private var ethereumMaxPriorityFee = ""
    @State private var nativeTokenPriceUSD: Decimal?
    @State private var solanaComputeUnitLimit = ""
    @State private var solanaPriorityFee = ""
    @State private var suiGasBudget = ""
    @State private var tronFeeLimit = ""
}

// MARK: - View

extension TransactionFeesView: View {
    var body: some View {
        ParameterSection(
            "\(blockchain.name) Fees",
            footer: footer,
            footerColor: footerColor,
            isFooterIndented: true
        ) {
            switch blockchain {
            case .aptos:
                aptosFeesForm
            case .bitcoin:
                bitcoinFeesForm
            case .cardano:
                cardanoFeesForm
            case .evm:
                evmFeesForm
            case .solana:
                solanaFeesForm
            case .sui:
                suiFeesForm
            case .tron:
                tronFeesForm
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
    var aptosFeesForm: some View {
        field("Gas unit price (octas)", text: $aptosGasUnitPrice, id: "transfer-aptos-gas-unit-price-field")
        field("Max gas", text: $aptosMaxGasAmount, id: "transfer-aptos-max-gas-field")
        ParameterRow("Max transaction cost (USD)", value: transactionCost)
    }

    @ViewBuilder
    var bitcoinFeesForm: some View {
        field("Fee rate (sat/vB)", text: $bitcoinFeeRate, id: "transfer-bitcoin-fee-rate-field")
        ParameterRow("Transaction cost (USD)", value: transactionCost)
    }

    @ViewBuilder
    var cardanoFeesForm: some View {
        ParameterRow("Network fee", value: cardanoFee)
        ParameterRow("Transaction cost (USD)", value: transactionCost)
    }

    @ViewBuilder
    var evmFeesForm: some View {
        ParameterRow("Base fee", value: ethereumBaseFee)
        field("Max priority fee per gas (gwei)", text: $ethereumMaxPriorityFee)
        field("Max fee per gas (gwei)", text: $ethereumMaxFee)
        ParameterRow("Transaction cost (USD)", value: transactionCost)
    }

    @ViewBuilder
    var solanaFeesForm: some View {
        field("Priority fee (µLamports/CU)", text: $solanaPriorityFee)
        field("Compute unit limit", text: $solanaComputeUnitLimit)
        ParameterRow("Transaction cost (USD)", value: transactionCost)
    }

    @ViewBuilder
    var suiFeesForm: some View {
        ParameterRow("Gas price (MIST)", value: estimatedFees?.suiGasPrice ?? "")
        field("Gas budget", text: $suiGasBudget)
        ParameterRow("Transaction cost (USD)", value: transactionCost)
    }

    @ViewBuilder
    var tronFeesForm: some View {
        field("TRC-20 fee limit (SUN)", text: $tronFeeLimit, isEnabled: isTronFeeLimitEnabled)

        // Not in Penpot: a dapp transaction's estimated burn, after the account's staked resources.
        if let burnedSun = estimatedFees?.nativeFeeReserve.flatMap({ UInt64($0) }) {
            ParameterRow("Estimated burn", value: TronTransactionParametersView.trx(burnedSun))
        }
    }

    /// An editable field, or its value as text when `isEditable` is `false`.
    @ViewBuilder
    func field(_ label: String, text: Binding<String>, id: String? = nil, isEnabled: Bool = true) -> some View {
        if isEditable {
            ParameterRow(label) {
                TextField("", text: text)
                    .disabled(!isEnabled)
                    .accessibilityIdentifier(id ?? "")
            }
        } else {
            ParameterRow(label, value: text.wrappedValue)
        }
    }
}

// MARK: - Logic

private extension TransactionFeesView {
    var ethereumBaseFee: String {
        guard let wei = estimatedFees?.ethereumBaseFee.flatMap({ BigUInt($0) }) else {
            return ""
        }

        // POSIX decimal point, matching the editable gwei fields below.
        let gwei = Decimal(sign: .plus, exponent: -9, significand: Decimal(wei))
        let format = Decimal.FormatStyle.number
            .precision(.fractionLength(0...2))
            .grouping(.never)
            .locale(Locale(identifier: "en_US_POSIX"))
        return "\(gwei.formatted(format)) gwei"
    }

    /// The fee of the transaction as built, in ADA. Cardano fees are fixed by
    /// transaction size (`min_fee_a × size + min_fee_b`), not bid.
    var cardanoFee: String {
        guard let lovelace = estimatedFees?.nativeFeeReserve.flatMap({ UInt64($0) }) else {
            return ""
        }

        let ada = Decimal(lovelace) / Decimal(1_000_000)
        return "\(ada.formatted(.number.precision(.fractionLength(0...6)))) ADA"
    }

    var footer: String? {
        switch blockchain {
        case .cardano:
            "The fee depends only on transaction size. It does not affect confirmation speed."
        case .tron:
            "This caps Energy and Bandwidth spending. It does not increase transaction priority."
        default:
            warning
        }
    }

    var footerColor: Color {
        switch blockchain {
        case .cardano, .tron:
            .secondary
        default:
            .caution
        }
    }

    func apply(_ estimate: Fees?) {
        aptosGasUnitPrice = estimate?.aptosGasUnitPrice ?? ""
        aptosMaxGasAmount = estimate?.aptosMaxGasAmount ?? ""
        bitcoinFeeRate = estimate?.bitcoinFeeRate ?? ""
        ethereumMaxFee = estimate?.ethereumMaxFee.flatMap(Gwei.string(fromWei:)) ?? ""
        ethereumMaxPriorityFee = estimate?.ethereumMaxPriorityFee.flatMap(Gwei.string(fromWei:)) ?? ""
        solanaComputeUnitLimit = estimate?.solanaComputeUnitLimit ?? ""
        solanaPriorityFee = estimate?.solanaPriorityFee ?? ""
        suiGasBudget = estimate?.suiGasBudget ?? ""
        tronFeeLimit = estimate?.tronFeeLimit ?? ""
    }

    /// Fetches the native token's USD price to convert
    /// `estimatedFees.nativeFeeReserve` into a USD cost.
    func loadNativeTokenPrice() async {
        do {
            let token = Token(address: nil, blockchain: blockchain, tokenInfo: blockchain.nativeToken)
            nativeTokenPriceUSD = try await DI.injectOrFail(TokenPriceService.self)
                .usdPrice(token, rpcURL: blockchain.rpcURL)
        } catch {
            printError("\(blockchain.displayName): \(error)")
            nativeTokenPriceUSD = nil
        }
    }

    /// Total network fee, converted from the chain's smallest unit into a
    /// formatted USD string. Empty when the estimate or price isn't available
    /// yet (for example, when no configured price source supports the chain).
    var transactionCost: String {
        guard
            let nativeFeeReserve = estimatedFees?.nativeFeeReserve,
            let feeAmount = BigUInt(nativeFeeReserve),
            let nativeTokenPriceUSD
        else {
            return ""
        }

        let decimalFee = Decimal(
            sign: .plus,
            exponent: -Int(blockchain.nativeToken.decimals),
            significand: Decimal(feeAmount)
        )

        let cost = decimalFee * nativeTokenPriceUSD
        return cost.formatted(.currency(code: "USD"))
    }

    var validatedFees: Fees? {
        guard isEditable else {
            return estimatedFees
        }

        switch blockchain {
        case .aptos:
            guard let price = UInt64(aptosGasUnitPrice), price > 0, let gas = UInt64(aptosMaxGasAmount), gas > 0 else {
                return nil
            }

            return Fees(aptosGasUnitPrice: aptosGasUnitPrice, aptosMaxGasAmount: aptosMaxGasAmount)

        case .bitcoin:
            guard UInt64(bitcoinFeeRate) != nil else {
                return nil
            }

            return Fees(bitcoinFeeRate: bitcoinFeeRate)

        case .cardano:
            // Nothing to edit: pass the estimate through so its fee stays with it.
            return estimatedFees

        case .evm:
            guard
                let maxPriorityFee = Gwei.wei(fromGwei: ethereumMaxPriorityFee),
                let maxFee = Gwei.wei(fromGwei: ethereumMaxFee)
            else {
                return nil
            }

            return Fees(
                ethereumBaseFee: estimatedFees?.ethereumBaseFee,
                ethereumMaxFee: maxFee.description,
                ethereumMaxPriorityFee: maxPriorityFee.description
            )

        case .solana:
            guard estimatedFees != nil else {
                return nil
            }

            guard solanaPriorityFee.isEmpty || UInt64(solanaPriorityFee) != nil else {
                return nil
            }

            guard solanaComputeUnitLimit.isEmpty || UInt32(solanaComputeUnitLimit) != nil else {
                return nil
            }

            return Fees(
                solanaComputeUnitLimit: solanaComputeUnitLimit.isEmpty ? nil : solanaComputeUnitLimit,
                solanaPriorityFee: solanaPriorityFee.isEmpty ? nil : solanaPriorityFee
            )

        case .sui:
            guard UInt64(suiGasBudget) != nil, let gasPrice = estimatedFees?.suiGasPrice, UInt64(gasPrice) != nil else {
                return nil
            }

            return Fees(suiGasBudget: suiGasBudget, suiGasPrice: gasPrice)

        case .tron:
            guard estimatedFees != nil else {
                return nil
            }

            guard isTronFeeLimitEnabled, !tronFeeLimit.isEmpty else {
                return Fees()
            }

            guard UInt64(tronFeeLimit) != nil else {
                return nil
            }

            return Fees(tronFeeLimit: tronFeeLimit)
        }
    }
}

// MARK: - Gwei

/// Exact conversion between wei strings and the gwei decimals shown for editing.
enum Gwei {
    private static let fractionDigits = 9

    /// `"26300000000"` → `"26.3"`. `nil` if `wei` isn't an unsigned integer.
    static func string(fromWei wei: String) -> String? {
        guard let value = BigUInt(wei) else {
            return nil
        }

        let divisor = BigUInt(10).power(fractionDigits)
        let whole = value / divisor
        var fraction = String(value % divisor)
        fraction = String(repeating: "0", count: fractionDigits - fraction.count) + fraction

        while fraction.hasSuffix("0") {
            fraction.removeLast()
        }

        return fraction.isEmpty ? "\(whole)" : "\(whole).\(fraction)"
    }

    /// `"26.3"` → `26300000000`. `nil` for anything but digits with at most
    /// nine fraction digits.
    static func wei(fromGwei gwei: String) -> BigUInt? {
        let parts = gwei.split(separator: ".", omittingEmptySubsequences: false)

        guard
            (1...2).contains(parts.count),
            let whole = parts.first, !whole.isEmpty, whole.allSatisfy(\.isASCIIDigit)
        else {
            return nil
        }

        let fraction = parts.count == 2 ? parts[1] : ""
        guard
            fraction.count <= fractionDigits,
            fraction.allSatisfy(\.isASCIIDigit),
            parts.count == 1 || !fraction.isEmpty
        else {
            return nil
        }

        let padded = fraction + String(repeating: "0", count: fractionDigits - fraction.count)
        return BigUInt(whole + padded)
    }
}

private extension Character {
    var isASCIIDigit: Bool {
        isASCII && isNumber
    }
}
