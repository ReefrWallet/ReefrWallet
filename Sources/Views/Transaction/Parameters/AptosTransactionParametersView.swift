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
            ParameterRow(String(localized: .commonSite), value: site)
        }

        ParameterSection(String(localized: .commonTransaction)) {
            FromRow(account: account)
            ParameterRow(
                String(localized: .commonFunction),
                value: preview.transaction.payload.identifier,
                lineLimit: 3
            )

            if !preview.transaction.payload.typeArguments.isEmpty {
                ParameterRow(
                    String(localized: .aptosTransactionParametersTypeArguments),
                    value: preview.transaction.payload.typeArguments.map(\.description).joined(separator: "\n"),
                    lineLimit: nil
                )
            }

            ParameterRow(
                String(localized: .aptosTransactionParametersArguments),
                value: "\(preview.transaction.payload.arguments.count)"
            )

            ParameterRow(
                String(localized: .aptosTransactionParametersSequenceNumber),
                value: "\(preview.transaction.sequenceNumber)"
            )

            ParameterRow(String(localized: .commonExpires), value: expiration)
        }

        ParameterBlock(String(localized: .commonRawBytes), text: preview.rawBytes.hexEncoded, maxLines: 6)
    }

    private var expiration: String {
        Date(timeIntervalSince1970: TimeInterval(preview.transaction.expirationTimestampSecs))
            .formatted(date: .abbreviated, time: .standard)
    }
}
