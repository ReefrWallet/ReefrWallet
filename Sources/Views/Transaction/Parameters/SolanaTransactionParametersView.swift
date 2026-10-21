//
//  SolanaTransactionParametersView.swift
//  Reefr Wallet
//
//  Created by Andrey Yurkevich on 30.09.26.
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import SwiftUI
import WalletKit

/// A `solana:signTransaction`/`solana:signAndSendTransaction` request's
/// decoded fields, plus the raw bytes for reference.
/// `preview.transaction` is always fully validated by the time this view
/// renders — ``SolanaDappProvider`` rejects an unparseable transaction or
/// one where the authorized account isn't a required signer before any
/// approval prompt.
///
/// Address-table lookups are shown only as a count: this codebase doesn't
/// resolve a lookup table's on-chain contents, so the addresses a v0
/// transaction's loaded accounts actually refer to can't be displayed
/// (see ADR-022).
struct SolanaTransactionParametersView: View {
    let account: Account
    let preview: SolanaTransactionPreview
    let site: String

    var body: some View {
        ParameterSection {
            ParameterRow("Site", value: site)
        }

        ParameterSection("Transaction") {
            FromRow(account: account)
            ParameterRow("Fee payer", value: preview.feePayer.string)
            ParameterRow("Version", value: versionText)
            ParameterRow("Required signers", value: "\(preview.transaction.header.numRequiredSignatures)")
            ParameterRow("Instructions", value: "\(preview.transaction.instructions.count)")
            ParameterRow("Programs", value: programsText, lineLimit: nil)

            if preview.transaction.addressTableLookupCount > 0 {
                ParameterRow(
                    "Lookup tables",
                    value: "\(preview.transaction.addressTableLookupCount) (addresses not resolved)"
                )
            }
        }

        ParameterBlock("Raw bytes", text: preview.rawBytes.hexEncoded, lineLimit: 3)
    }

    private var versionText: String {
        switch preview.transaction.version {
        case .legacy: "Legacy"
        case .v0: "v0"
        }
    }

    private var programsText: String {
        guard !preview.programIds.isEmpty else {
            return "None"
        }

        return preview.programIds.map(Self.programName).joined(separator: ", ")
    }

    private static func programName(_ address: SolanaAddress) -> String {
        switch address {
        case SolanaProgram.system: "System"
        case SolanaProgram.token: "Token"
        case SolanaProgram.token2022: "Token-2022"
        case SolanaProgram.associatedToken: "Associated Token Account"
        case SolanaProgram.computeBudget: "Compute Budget"
        default: address.string
        }
    }
}
