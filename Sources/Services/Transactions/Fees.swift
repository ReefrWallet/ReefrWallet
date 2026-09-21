//
//  Fees.swift
//  Reefr Wallet
//
//  Created by Andrey Yurkevich on 02.03.26.
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import BigInt
import WalletKit

struct Fees: Equatable {
    let ethereumBaseFee: String?
    let ethereumGasPrice: String?
    let ethereumMaxPriorityFee: String?
    let ethereumMaxFee: String?
    let suiGasBudget: String?
    let suiGasPrice: String?
    /// The fee rate, in sat/vB, for a Bitcoin transfer.
    let bitcoinFeeRate: String?
    /// Maximum SUN a TRC-20 call may spend. This does not affect validator priority.
    let tronFeeLimit: String?
    /// The Solana priority fee, in micro-lamports per compute unit.
    let solanaPriorityFee: String?
    /// The Solana compute-unit limit, if overridden. `nil` leaves the
    /// runtime's default per-instruction budget in effect.
    let solanaComputeUnitLimit: String?
    /// Total fee cost in the chain's smallest unit (wei / MIST / sats / lamports),
    /// only set when the token being sent is the native asset. Used to compute the
    /// spendable maximum after reserving gas.
    let nativeFeeReserve: String?

    init(
        ethereumBaseFee: String? = nil,
        ethereumGasPrice: String? = nil,
        ethereumMaxPriorityFee: String? = nil,
        ethereumMaxFee: String? = nil,
        suiGasBudget: String? = nil,
        suiGasPrice: String? = nil,
        bitcoinFeeRate: String? = nil,
        tronFeeLimit: String? = nil,
        solanaPriorityFee: String? = nil,
        solanaComputeUnitLimit: String? = nil,
        nativeFeeReserve: String? = nil
    ) {
        self.ethereumBaseFee = ethereumBaseFee
        self.ethereumGasPrice = ethereumGasPrice
        self.ethereumMaxPriorityFee = ethereumMaxPriorityFee
        self.ethereumMaxFee = ethereumMaxFee
        self.suiGasBudget = suiGasBudget
        self.suiGasPrice = suiGasPrice
        self.bitcoinFeeRate = bitcoinFeeRate
        self.tronFeeLimit = tronFeeLimit
        self.solanaPriorityFee = solanaPriorityFee
        self.solanaComputeUnitLimit = solanaComputeUnitLimit
        self.nativeFeeReserve = nativeFeeReserve
    }
}
