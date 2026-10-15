//
//  AptosPreviewViews.swift
//  Reefr Wallet
//
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import SwiftUI
import WalletKit

/// Shows the exact AIP-62 full message the wallet will sign.
struct AptosMessagePreviewView: View {
    let fullMessage: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Message")
                .style(.small, foreground: .secondary)

            Text(fullMessage)
                .style(.medium)
                .textSelection(.enabled)
        }
    }
}

/// Shows an `aptos:signTransaction` request's decoded fields. The provider
/// rejects undecodable, wrong-sender, or wrong-chain transactions first.
struct AptosTransactionPreviewView: View {
    let preview: AptosTransactionPreview

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            row("Function", preview.transaction.payload.identifier, selectable: true)

            if !preview.transaction.payload.typeArguments.isEmpty {
                row(
                    "Type arguments",
                    preview.transaction.payload.typeArguments.map(\.description).joined(separator: "\n"),
                    selectable: true
                )
            }

            row("Arguments", "\(preview.transaction.payload.arguments.count)")
            row("Max gas", "\(preview.transaction.maxGasAmount) units at \(preview.transaction.gasUnitPrice) octas")
            row("Max fee", "\(maxFee) octas")
            row("Sequence number", "\(preview.transaction.sequenceNumber)")
            row("Expires", expiration)
            row("Raw bytes", "0x" + preview.rawBytes.map { String(format: "%02x", $0) }.joined(), selectable: true)
        }
    }

    private var maxFee: UInt64 {
        let transaction = preview.transaction
        let (fee, overflow) = transaction.maxGasAmount.multipliedReportingOverflow(by: transaction.gasUnitPrice)
        return overflow ? .max : fee
    }

    private var expiration: String {
        Date(timeIntervalSince1970: TimeInterval(preview.transaction.expirationTimestampSecs))
            .formatted(date: .abbreviated, time: .standard)
    }

    private func row(_ title: String, _ value: String, selectable: Bool = false) -> some View {
        LabeledContent {
            Text(value)
                .style(.medium)
                .textSelection(.enabled)
                .lineLimit(selectable ? 3 : 1)
        } label: {
            Text(title)
                .style(.small, foreground: .secondary)
        }
    }
}
