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
    let site: String

    var body: some View {
        ParameterSection {
            ParameterRow(String(localized: .commonSite), value: site)
        }

        ParameterSection(String(localized: .commonTransaction)) {
            FromRow(account: account)
            ParameterRow(
                String(localized: .commonTo),
                value: call.to ?? String(localized: .ethereumTransactionParametersContractCreation)
            )

            ParameterRow(String(localized: .commonValue), value: call.value.description + " wei")
        }

        if !call.data.isEmpty {
            ParameterBlock(
                String(localized: .ethereumTransactionParametersData),
                text: call.data.hexEncoded,
                maxLines: 4
            )
        }
    }
}
