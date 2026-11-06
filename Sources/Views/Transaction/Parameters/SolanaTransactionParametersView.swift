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
            ParameterRow(String(localized: .commonSite), value: site)
        }

        ParameterSection(String(localized: .commonTransaction)) {
            FromRow(account: account)
            ParameterRow(String(localized: .solanaTransactionParametersFeePayer), value: preview.feePayer.string)
            ParameterRow(String(localized: .commonVersion), value: versionText)
            ParameterRow(
                String(localized: .commonRequiredSigners),
                value: "\(preview.transaction.header.numRequiredSignatures)"
            )

            ParameterRow(
                String(localized: .solanaTransactionParametersInstructions),
                value: "\(preview.transaction.instructions.count)"
            )

            ParameterRow(String(localized: .solanaTransactionParametersPrograms), value: programsText, lineLimit: nil)

            if preview.transaction.addressTableLookupCount > 0 {
                ParameterRow(
                    String(localized: .solanaTransactionParametersLookupTables),
                    value: String(
                        localized: .solanaTransactionParametersAddressesNotResolved(
                            String(preview.transaction.addressTableLookupCount)
                        )
                    )
                )
            }
        }

        ParameterBlock(String(localized: .commonRawBytes), text: preview.rawBytes.hexEncoded, maxLines: 6)
    }

    private var versionText: String {
        switch preview.transaction.version {
        case .legacy: String(localized: .solanaTransactionParametersLegacy)
        case .v0: "v0"
        }
    }

    private var programsText: String {
        guard !preview.programIds.isEmpty else {
            return String(localized: .commonNone)
        }

        return preview.programIds.map(Self.programName).joined(separator: ", ")
    }

    private static func programName(_ address: SolanaAddress) -> String {
        switch address {
        case SolanaProgram.system: String(localized: .solanaTransactionParametersSystem)
        case SolanaProgram.token: String(localized: .commonToken)
        case SolanaProgram.token2022: String(localized: .solanaTransactionParametersToken2022)
        case SolanaProgram.associatedToken: String(localized: .solanaTransactionParametersAssociatedTokenAccount)
        case SolanaProgram.computeBudget: String(localized: .solanaTransactionParametersComputeBudget)
        case SolanaProgram.stake: String(localized: .solanaTransactionParametersStake)
        default: address.string
        }
    }
}
