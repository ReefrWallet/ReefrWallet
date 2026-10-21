//
//  EthereumTransactionParametersView.swift
//  Reefr Wallet
//
//  Created by Andrey Yurkevich on 25.09.26.
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import SwiftUI
import WalletKit

/// An `eth_sendTransaction` call's From/To/Value and calldata. Gas and fees
/// are shown by ``TransactionFeesView``.
struct EthereumTransactionParametersView: View {
    let account: Account
    let call: EthereumCallPreview

    var body: some View {
        ParameterSection("Transaction") {
            FromRow(account: account)
            ParameterRow("To", value: call.to ?? "Contract creation")
            ParameterRow("Value", value: call.value.description + " wei")
        }

        if !call.data.isEmpty {
            ParameterBlock("Data", text: call.data.hexEncoded, lineLimit: 4)
        }
    }
}
