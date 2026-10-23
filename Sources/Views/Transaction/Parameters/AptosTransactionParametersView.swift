//
//  AptosTransactionParametersView.swift
//  Reefr Wallet
//
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import SwiftUI
import WalletKit

/// An `aptos:signTransaction` request's decoded fields. The provider rejects
/// undecodable, wrong-sender, or wrong-chain transactions first. Gas is shown
/// by ``TransactionFeesView``.
struct AptosTransactionParametersView: View {
    let account: Account
    let preview: AptosTransactionPreview
    let site: String

    var body: some View {
        ParameterSection {
            ParameterRow("Site", value: site)
        }

        ParameterSection("Transaction") {
            FromRow(account: account)
            ParameterRow("Function", value: preview.transaction.payload.identifier, lineLimit: 3)

            if !preview.transaction.payload.typeArguments.isEmpty {
                ParameterRow(
                    "Type arguments",
                    value: preview.transaction.payload.typeArguments.map(\.description).joined(separator: "\n"),
                    lineLimit: nil
                )
            }

            ParameterRow("Arguments", value: "\(preview.transaction.payload.arguments.count)")
            ParameterRow("Sequence number", value: "\(preview.transaction.sequenceNumber)")
            ParameterRow("Expires", value: expiration)
        }

        ParameterBlock("Raw bytes", text: preview.rawBytes.hexEncoded, maxLines: 6)
    }

    private var expiration: String {
        Date(timeIntervalSince1970: TimeInterval(preview.transaction.expirationTimestampSecs))
            .formatted(date: .abbreviated, time: .standard)
    }
}
