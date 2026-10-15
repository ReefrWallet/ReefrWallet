//
//  EthereumCallPreviewView.swift
//  Reefr Wallet
//
//  Created by Andrey Yurkevich on 25.09.26.
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import SwiftUI
import WalletKit

/// Shows an `eth_sendTransaction` call's `to`/`value`/`data` fields plus
/// its estimated (and user-editable) fees, via ``TransactionFeesView``.
struct EthereumCallPreviewView: View {
    let blockchain: Blockchain
    let call: EthereumCallPreview
    let estimatedFees: Fees

    @Binding var fees: Fees?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            LabeledContent {
                Text(call.to ?? "Contract creation")
                    .style(.medium)
                    .textSelection(.enabled)
            } label: {
                Text("To")
                    .style(.small, foreground: .secondary)
            }

            LabeledContent {
                Text(call.value.description + " wei")
                    .style(.medium)
            } label: {
                Text("Value")
                    .style(.small, foreground: .secondary)
            }

            if !call.data.isEmpty {
                LabeledContent {
                    Text(dataPreview)
                        .style(.small)
                        .textSelection(.enabled)
                        .lineLimit(3)
                } label: {
                    Text("Data")
                        .style(.small, foreground: .secondary)
                }
            }

            LabeledContent {
                Text(call.gasLimit.description)
                    .style(.medium)
            } label: {
                Text("Gas limit")
                    .style(.small, foreground: .secondary)
            }

            LabeledContent {
                Text(maxTotalCost)
                    .style(.medium)
            } label: {
                Text("Max network fee")
                    .style(.small, foreground: .secondary)
            }

            if call.hasDappFeeOverrides {
                Text("Gas limit or fees were set by the site.")
                    .style(.small, foreground: .orange)
            }

            Form {
                TransactionFeesView(blockchain: blockchain, estimatedFees: estimatedFees, fees: $fees)
            }
        }
    }

    private var dataPreview: String {
        "0x" + call.data.map { String(format: "%02x", $0) }.joined()
    }

    /// `gasLimit × maxFeePerGas` at the currently edited (or estimated) cap.
    private var maxTotalCost: String {
        guard let maxFee = (fees ?? estimatedFees).ethereumMaxFee.flatMap({ BigUInt($0) }) else {
            return "—"
        }

        let wei = call.gasLimit * maxFee
        let amount = Decimal(sign: .plus, exponent: -Int(blockchain.nativeToken.decimals), significand: Decimal(wei))
        return "\(amount.formatted()) \(blockchain.nativeToken.symbol)"
    }
}
