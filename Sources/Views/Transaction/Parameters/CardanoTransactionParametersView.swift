//
//  CardanoTransactionParametersView.swift
//  Reefr Wallet
//
//  Created by Andrey Yurkevich on 27.10.26.
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import Foundation
import SwiftUI
import WalletKit

/// A dapp-supplied Cardano transaction (CIP-30 `signTx`) decoded from its
/// original bytes: which of the account's keys sign, who else still has to,
/// and what the transaction spends, creates, mints and delegates. The fee is
/// shown by ``TransactionFeesView``.
struct CardanoTransactionParametersView: View {
    let account: Account
    let preview: CardanoTransactionPreview
    let site: String

    var body: some View {
        ParameterSection {
            ParameterRow(String(localized: .commonSite), value: site)
        }

        ParameterSection(String(localized: .commonTransaction)) {
            FromRow(account: account)

            ForEach(Self.rows(for: preview), id: \.label) { row in
                ParameterRow(row.label, value: row.value, lineLimit: nil)
            }
        }

        ParameterBlock(String(localized: .commonRawBytes), text: preview.rawBytes.hexEncoded, maxLines: 3)
    }
}

// MARK: - Rows

extension CardanoTransactionParametersView {
    struct Row: Equatable {
        let label: String
        let value: String
    }

    /// The rows after From, in Penpot's order; rows with nothing to show are left out.
    static func rows(for preview: CardanoTransactionPreview) -> [Row] {
        let transaction = preview.transaction
        let row = { (label: LocalizedStringResource, value: String) in
            Row(label: String(localized: label), value: value)
        }

        var rows = [row(.commonSignsWith, keyNames(preview.signingPaths))]

        if preview.missingSignerCount > 0 {
            rows.append(row(.cardanoTransactionParametersOtherSigners, "\(preview.missingSignerCount) · sign after you"))
        } else if preview.validWitnessCount > 0 {
            rows.append(row(.cardanoTransactionParametersOtherSigners, "\(preview.validWitnessCount) already signed"))
        }

        if preview.unresolvedCount > 0 {
            // Not in Penpot: requirements the wallet couldn't look up are not signers.
            rows.append(row(.cardanoTransactionParametersNotChecked, "\(preview.unresolvedCount) requirement(s)"))
        }

        if let ttl = transaction.ttl {
            rows.append(row(.cardanoTransactionParametersValidUntil, String(localized: .commonSlotNumber(String(ttl)))))
        }

        rows.append(row(.cardanoTransactionParametersInputs, "\(transaction.inputs.count)"))
        let outputs = transaction.outputs.map(describe).joined(separator: "\n")
        rows.append(row(.cardanoTransactionParametersOutputs, outputs))

        if !transaction.mint.isEmpty {
            let mint = transaction.mint.map(describeMint).joined(separator: "\n")
            rows.append(row(.cardanoTransactionParametersMint, mint))
        }

        if !transaction.certificates.isEmpty {
            let kinds = transaction.certificates.map(\.kind).joined(separator: ", ")
            rows.append(row(.cardanoTransactionParametersCertificates, kinds))
        }

        if !transaction.withdrawals.isEmpty {
            let total = transaction.withdrawals.reduce(into: Decimal(0)) { $0 += lovelace($1.lovelace) }
            rows.append(row(.cardanoTransactionParametersWithdrawals, ada(total)))
        }

        if !transaction.collateral.isEmpty {
            rows.append(row(.cardanoTransactionParametersCollateral, "\(transaction.collateral.count)"))
        }

        if !transaction.requiredSigners.isEmpty {
            rows.append(row(.commonRequiredSigners, "\(transaction.requiredSigners.count) key hashes"))
        }

        return rows
    }

    static func keyNames(_ paths: [CardanoSigningPath]) -> String {
        paths.map { path in
            switch path.role {
            case 2: "Stake"
            case 1: "Change #\(path.index)"
            default: "Payment #\(path.index)"
            }
        }
        .joined(separator: ", ")
    }

    private static func describe(_ output: CardanoDappTransaction.Output) -> String {
        var amount = ada(lovelace(output.lovelace))
        if !output.assets.isEmpty {
            amount += " + \(output.assets.count) token\(output.assets.count == 1 ? "" : "s")"
        }

        return "\(amount) → \(shortened(output.address))"
    }

    private static func describeMint(_ asset: CardanoDappTransaction.Asset) -> String {
        let sign = asset.quantity.hasPrefix("-") ? "" : "+"
        let name = String(data: asset.name, encoding: .utf8).flatMap { $0.isEmpty ? nil : $0 }
            ?? (asset.name.isEmpty ? "(unnamed)" : asset.name.hexEncoded)

        return "\(sign)\(asset.quantity) \(name) · policy \(shortened(asset.policyId.hexEncoded.dropFirst(2).description))"
    }

    private static func lovelace(_ text: String) -> Decimal {
        Decimal(string: text) ?? 0
    }

    private static func ada(_ lovelace: Decimal) -> String {
        (lovelace / 1_000_000).formatted(symbol: "ADA")
    }

    private static func shortened(_ text: String) -> String {
        guard text.count > 20 else {
            return text
        }

        return "\(text.prefix(12))…\(text.suffix(6))"
    }
}
