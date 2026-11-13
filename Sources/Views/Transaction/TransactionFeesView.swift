// swiftlint:disable file_length
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

/// The "<Chain> Fees" section of ``TransactionSheet``, per the Penpot `Fees` component.
struct TransactionFeesView {
    let blockchain: Blockchain
    /// Fees fetched from the network, pushed into the editable fields whenever it
    /// changes. `nil` clears them, which is what keeps "Next" disabled while a
    /// fresh estimate is in flight.
    let estimatedFees: Fees?
    /// `false` shows every value as text; `fees` then mirrors `estimatedFees`.
    var isEditable = true
    /// `false` for TRX transfers and staking, which don't call a contract and so have no fee limit.
    var isTronFeeLimitEnabled = true
    /// The Penpot `Fees` `Solana Staking` variant: the total instead of its compute budget.
    var isSolanaStaking = false
    /// The `Sui Staking` variant: the fee after the storage rebate, which can't be edited.
    var isSuiStaking = false
    /// The Penpot `Fees` `Cardano Staking` variant: the deposit paid, or the refund received.
    var cardanoStaking: CardanoStakingFeeLines?
    /// Not in Penpot: a caution note under the section, e.g. dapp-set fees.
    var warning: String?
    var ethereumGasLimit: BigUInt?

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
            footerColor: footerColor
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
            case .ton:
                tonFeesForm
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
        field(
            String(localized: .transactionFeesGasUnitPrice),
            text: $aptosGasUnitPrice,
            id: "transfer-aptos-gas-unit-price-field"
        )

        field(String(localized: .transactionFeesMaxGas), text: $aptosMaxGasAmount, id: "transfer-aptos-max-gas-field")
        TransactionCostRow(label: .transactionFeesMaxTransactionCost, value: transactionCost)
    }

    @ViewBuilder
    var bitcoinFeesForm: some View {
        field(String(localized: .transactionFeesFeeRate), text: $bitcoinFeeRate, id: "transfer-bitcoin-fee-rate-field")
        TransactionCostRow(value: transactionCost)
    }

    @ViewBuilder
    var cardanoFeesForm: some View {
        ParameterRow(String(localized: .transactionFeesNetworkFee), value: cardanoFee)

        if let cardanoStaking {
            if cardanoStaking.deposit > 0 {
                ParameterRow(
                    String(localized: .cardanoStakingFeesDeposit),
                    value: CardanoStakingFormat.ada(cardanoStaking.deposit)
                )
            }

            if cardanoStaking.refund > 0 {
                ParameterRow(
                    String(localized: .cardanoStakingFeesRefund),
                    value: CardanoStakingFormat.ada(cardanoStaking.refund)
                )
            }
        }

        TransactionCostRow(value: transactionCost)
    }

    @ViewBuilder
    var evmFeesForm: some View {
        ParameterRow(String(localized: .transactionFeesBaseFee), value: ethereumBaseFee)
        field(String(localized: .transactionFeesMaxPriorityFee), text: $ethereumMaxPriorityFee)
        field(String(localized: .transactionFeesMaxFee), text: $ethereumMaxFee)
        TransactionCostRow(value: transactionCost)
    }

    @ViewBuilder
    var solanaFeesForm: some View {
        if isSolanaStaking {
            ParameterRow(String(localized: .transactionFeesNetworkFee), value: solanaNetworkFee)
        } else {
            field(String(localized: .transactionFeesPriorityFee), text: $solanaPriorityFee)
            field(String(localized: .transactionFeesComputeUnitLimit), text: $solanaComputeUnitLimit)
        }

        TransactionCostRow(value: transactionCost)
    }

    @ViewBuilder
    var suiFeesForm: some View {
        if isSuiStaking {
            ParameterRow(String(localized: .transactionFeesNetworkFee), value: suiNetworkFee)
        } else {
            ParameterRow(String(localized: .transactionFeesGasPrice), value: estimatedFees?.suiGasPrice ?? "")
            field(String(localized: .transactionFeesGasBudget), text: $suiGasBudget)
        }

        TransactionCostRow(value: transactionCost)
    }

    @ViewBuilder
    var tonFeesForm: some View {
        ParameterRow(String(localized: .transactionFeesNetworkFee), value: estimatedFees?.nativeFeeReserve ?? "")
        TransactionCostRow(value: transactionCost)
    }

    /// Every Tron transaction (transfers, dapp requests, staking) shows what it uses and whether
    /// the account's staked and free bandwidth and energy cover it, then the TRX burned for the rest.
    @ViewBuilder
    var tronFeesForm: some View {
        if isTronFeeLimitEnabled, isEditable || !tronFeeLimit.isEmpty {
            field(String(localized: .transactionFeesTrc20FeeLimit), text: $tronFeeLimit)
        }

        if let fee = estimatedFees?.tronFee {
            ParameterRow(
                String(localized: .tronTransactionParametersBandwidth),
                value: fee.bandwidth.formatted(.number),
                subtitle: tronCoverage(
                    isCovered: fee.isBandwidthCovered,
                    burnSun: fee.bandwidthBurnSun,
                    available: fee.availableBandwidth
                )
            )

            if fee.energy > 0 {
                ParameterRow(
                    String(localized: .tronTransactionParametersEnergy),
                    value: fee.energy.formatted(.number),
                    subtitle: tronCoverage(
                        isCovered: fee.isEnergyCovered,
                        burnSun: fee.energyBurnSun,
                        available: fee.availableEnergy
                    )
                )
            }
        } else {
            ParameterRow(String(localized: .transactionFeesNetworkFee), value: "")
        }

        TransactionCostRow(value: transactionCost)
    }

    /// "Covered by your resources (810 available)", or what burning the shortfall costs.
    func tronCoverage(isCovered: Bool, burnSun: UInt64, available: UInt64) -> String {
        let available = available.formatted(.number)

        return isCovered
            ? String(localized: .tronFeesCovered(available))
            : String(localized: .tronFeesBurned(TronTransactionParametersView.trx(burnSun), available))
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
        return String(localized: .transactionFeesGwei(gwei.formatted(format)))
    }

    /// The fee of the transaction as built, in ADA. Cardano fees are fixed by
    /// transaction size (`min_fee_a × size + min_fee_b`), not bid.
    var cardanoFee: String {
        guard let lovelace = estimatedFees?.nativeFeeReserve.flatMap({ UInt64($0) }) else {
            return ""
        }

        let ada = Decimal(lovelace) / Decimal(1_000_000)
        return ada.formatted(symbol: "ADA")
    }

    /// The fee of the transaction as built, in SOL, priority fee included.
    var solanaNetworkFee: String {
        guard let lamports = estimatedFees?.nativeFeeReserve.flatMap({ UInt64($0) }) else {
            return ""
        }

        return SolanaStakingFormat.sol(lamports)
    }

    /// The simulated cost of the staking transaction as built, in SUI.
    var suiNetworkFee: String {
        estimatedFees?.nativeFeeReserve.flatMap { UInt64($0) }.map(SuiStakingFormat.sui) ?? ""
    }

    var footer: String? {
        switch blockchain {
        case .cardano where cardanoStaking != nil:
            warning ?? String(localized: .cardanoStakingFeesNote)
        case .cardano:
            warning ?? String(localized: .transactionFeesFeeSizeNote)
        case .solana where isSolanaStaking:
            warning ?? String(localized: .solanaStakingNoteFees)
        case .sui where isSuiStaking:
            warning ?? String(localized: .suiStakingNoteFees)
        case .tron:
            tronFooter
        default:
            warning
        }
    }

    /// Why the transaction couldn't be built, else how the fee limit and the account's resources work.
    var tronFooter: String {
        if let warning {
            return warning
        }

        let note = String(localized: .tronFeesNote)

        return isTronFeeLimitEnabled ? "\(String(localized: .transactionFeesFeeLimitNote)) \(note)" : note
    }

    var footerColor: Color {
        switch blockchain {
        case .cardano where cardanoStaking != nil:
            warning == nil ? .secondary : .caution
        case .cardano:
            warning == nil ? .secondary : .caution
        case .solana where isSolanaStaking, .sui where isSuiStaking, .tron:
            warning == nil ? .secondary : .caution
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
        let nativeFeeReserve = ethereumGasLimit == nil
            ? estimatedFees?.nativeFeeReserve : validatedFees?.nativeFeeReserve
        guard
            let nativeFeeReserve,
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
        return "\(cost.formattedAbbreviated()) US$"
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
                let maxFee = Gwei.wei(fromGwei: ethereumMaxFee),
                maxFee > 0, maxFee.bitWidth <= 256, maxPriorityFee <= maxFee
            else {
                return nil
            }

            return Fees(
                ethereumBaseFee: estimatedFees?.ethereumBaseFee,
                ethereumMaxFee: maxFee.description,
                ethereumMaxPriorityFee: maxPriorityFee.description,
                nativeFeeReserve: ethereumGasLimit.map { ($0 * maxFee).description }
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

        case .ton:
            // Nothing to edit: pass the estimate through so its fee stays with it.
            return estimatedFees

        case .tron:
            guard estimatedFees != nil else {
                return nil
            }

            guard isTronFeeLimitEnabled, !tronFeeLimit.isEmpty else {
                return Fees()
            }

            guard let limit = UInt64(tronFeeLimit), limit <= UInt64(Int64.max) else {
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
