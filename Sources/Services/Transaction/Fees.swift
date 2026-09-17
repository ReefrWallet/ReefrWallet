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
    /// Total fee cost in the chain's smallest unit (wei / MIST), only set when
    /// the token being sent is the native asset. Used to compute the spendable
    /// maximum after reserving gas.
    let nativeFeeReserve: String?

    init(
        ethereumBaseFee: String? = nil,
        ethereumGasPrice: String? = nil,
        ethereumMaxPriorityFee: String? = nil,
        ethereumMaxFee: String? = nil,
        suiGasBudget: String? = nil,
        suiGasPrice: String? = nil,
        nativeFeeReserve: String? = nil
    ) {
        self.ethereumBaseFee = ethereumBaseFee
        self.ethereumGasPrice = ethereumGasPrice
        self.ethereumMaxPriorityFee = ethereumMaxPriorityFee
        self.ethereumMaxFee = ethereumMaxFee
        self.suiGasBudget = suiGasBudget
        self.suiGasPrice = suiGasPrice
        self.nativeFeeReserve = nativeFeeReserve
    }
}
