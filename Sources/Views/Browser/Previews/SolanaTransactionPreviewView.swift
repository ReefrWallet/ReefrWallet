//
//  SolanaTransactionPreviewView.swift
//  Reefr Wallet
//
//  Created by Andrey Yurkevich on 30.09.26.
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import SwiftUI
import WalletKit

/// Shows a `solana:signTransaction`/`solana:signAndSendTransaction`
/// request's decoded fields, plus the raw bytes for reference.
/// `preview.transaction` is always fully validated by the time this view
/// renders — ``SolanaDappProvider`` rejects an unparseable transaction or
/// one where the authorized account isn't a required signer before any
/// approval prompt — mirrors ``SuiTransactionPreviewView``.
///
/// Address-table lookups are shown only as a count: this codebase doesn't
/// resolve a lookup table's on-chain contents, so the addresses a v0
/// transaction's loaded accounts actually refer to can't be displayed
/// (see ADR-022).
struct SolanaTransactionPreviewView: View {
    let preview: SolanaTransactionPreview

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            LabeledContent {
                Text(preview.feePayer.string)
                    .style(.medium)
                    .textSelection(.enabled)
            } label: {
                Text("Fee payer")
                    .style(.small, foreground: .secondary)
            }

            LabeledContent {
                Text(versionText)
                    .style(.medium)
            } label: {
                Text("Version")
                    .style(.small, foreground: .secondary)
            }

            LabeledContent {
                Text("\(preview.transaction.header.numRequiredSignatures)")
                    .style(.medium)
            } label: {
                Text("Required signers")
                    .style(.small, foreground: .secondary)
            }

            LabeledContent {
                Text("\(preview.transaction.instructions.count)")
                    .style(.medium)
            } label: {
                Text("Instructions")
                    .style(.small, foreground: .secondary)
            }

            LabeledContent {
                Text(programsText)
                    .style(.medium)
                    .textSelection(.enabled)
            } label: {
                Text("Programs")
                    .style(.small, foreground: .secondary)
            }

            if preview.transaction.addressTableLookupCount > 0 {
                LabeledContent {
                    Text("\(preview.transaction.addressTableLookupCount) (addresses not resolved)")
                        .style(.medium)
                } label: {
                    Text("Lookup tables")
                        .style(.small, foreground: .secondary)
                }
            }

            LabeledContent {
                Text(rawBytesPreview)
                    .style(.small)
                    .textSelection(.enabled)
                    .lineLimit(3)
            } label: {
                Text("Raw bytes")
                    .style(.small, foreground: .secondary)
            }
        }
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

    private var rawBytesPreview: String {
        "0x" + preview.rawBytes.map { String(format: "%02x", $0) }.joined()
    }
}
