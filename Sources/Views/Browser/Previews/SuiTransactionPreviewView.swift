//
//  SuiTransactionPreviewView.swift
//  Reefr Wallet
//
//  Created by Andrey Yurkevich on 30.09.26.
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import SwiftUI
import WalletKit

/// Shows a `sui:signTransaction`/`sui:signAndExecuteTransaction`
/// request's decoded sender/gas fields, plus the raw bytes for
/// reference. `preview.summary` is always fully validated by the time
/// this view renders — ``SuiDappProvider`` rejects an undecodable or
/// sender-mismatched transaction before any approval prompt — so there's
/// no "decoding failed" state to show here.
struct SuiTransactionPreviewView: View {
    let preview: SuiTransactionPreview

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            LabeledContent {
                Text(preview.summary.sender.string)
                    .style(.medium)
                    .textSelection(.enabled)
            } label: {
                Text("Sender")
                    .style(.small, foreground: .secondary)
            }

            LabeledContent {
                Text("\(preview.summary.commandCount)")
                    .style(.medium)
            } label: {
                Text("Commands")
                    .style(.small, foreground: .secondary)
            }

            if !moveCallDescriptions.isEmpty {
                LabeledContent {
                    VStack(alignment: .trailing, spacing: 4) {
                        ForEach(Array(moveCallDescriptions.enumerated()), id: \.offset) { _, description in
                            Text(description)
                                .style(.medium)
                                .textSelection(.enabled)
                        }
                    }
                } label: {
                    Text("Move calls")
                        .style(.small, foreground: .secondary)
                }
            }

            LabeledContent {
                Text("\(preview.summary.gasBudget) MIST")
                    .style(.medium)
            } label: {
                Text("Gas budget")
                    .style(.small, foreground: .secondary)
            }

            LabeledContent {
                Text("\(preview.summary.gasPrice) MIST")
                    .style(.medium)
            } label: {
                Text("Gas price")
                    .style(.small, foreground: .secondary)
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

    /// Each decoded Move call as `package::module::function`, with the
    /// full package address — on an approval screen the user must be
    /// able to tell exactly which package will run.
    var moveCallDescriptions: [String] {
        preview.summary.moveCalls.map { "\($0.package.string)::\($0.module)::\($0.function)" }
    }

    private var rawBytesPreview: String {
        "0x" + preview.rawBytes.map { String(format: "%02x", $0) }.joined()
    }
}
