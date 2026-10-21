//
//  Fees.swift
//  Reefr Wallet
//
//  Created by Andrey Yurkevich on 02.03.26.
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

struct Fees: Equatable {
    /// Aptos octas per gas unit.
    let aptosGasUnitPrice: String?
    /// Aptos gas units the transaction may consume.
    let aptosMaxGasAmount: String?

    /// The fee rate, in sat/vB, for a Bitcoin transfer.
    let bitcoinFeeRate: String?

    /// Lovelace carried alongside a Cardano native asset at the recipient.
    let cardanoRecipientLovelace: String?

    let ethereumBaseFee: String?
    let ethereumGasPrice: String?
    let ethereumMaxPriorityFee: String?
    let ethereumMaxFee: String?

    /// The Solana compute-unit limit, if overridden. `nil` leaves the
    /// runtime's default per-instruction budget in effect.
    let solanaComputeUnitLimit: String?
    /// The Solana priority fee, in µLamports per compute unit.
    let solanaPriorityFee: String?

    let suiGasBudget: String?
    let suiGasPrice: String?

    /// Maximum SUN a TRC-20 call may spend. This does not affect validator priority.
    let tronFeeLimit: String?

    /// Total fee cost in the chain's smallest unit: the USD cost shown, and the
    /// gas reserved from a native-asset send's spendable maximum.
    let nativeFeeReserve: String?

    init(
        aptosGasUnitPrice: String? = nil,
        aptosMaxGasAmount: String? = nil,
        bitcoinFeeRate: String? = nil,
        cardanoRecipientLovelace: String? = nil,
        ethereumBaseFee: String? = nil,
        ethereumGasPrice: String? = nil,
        ethereumMaxFee: String? = nil,
        ethereumMaxPriorityFee: String? = nil,
        nativeFeeReserve: String? = nil,
        solanaComputeUnitLimit: String? = nil,
        solanaPriorityFee: String? = nil,
        suiGasBudget: String? = nil,
        suiGasPrice: String? = nil,
        tronFeeLimit: String? = nil
    ) {
        self.aptosGasUnitPrice = aptosGasUnitPrice
        self.aptosMaxGasAmount = aptosMaxGasAmount
        self.bitcoinFeeRate = bitcoinFeeRate
        self.cardanoRecipientLovelace = cardanoRecipientLovelace
        self.ethereumBaseFee = ethereumBaseFee
        self.ethereumGasPrice = ethereumGasPrice
        self.ethereumMaxFee = ethereumMaxFee
        self.ethereumMaxPriorityFee = ethereumMaxPriorityFee
        self.nativeFeeReserve = nativeFeeReserve
        self.solanaComputeUnitLimit = solanaComputeUnitLimit
        self.solanaPriorityFee = solanaPriorityFee
        self.suiGasBudget = suiGasBudget
        self.suiGasPrice = suiGasPrice
        self.tronFeeLimit = tronFeeLimit
    }
}
