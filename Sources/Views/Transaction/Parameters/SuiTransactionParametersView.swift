//
//  SuiTransactionParametersView.swift
//  Reefr Wallet
//
//  Created by Andrey Yurkevich on 30.09.26.
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import SwiftUI
import WalletKit

/// A `sui:signTransaction`/`sui:signAndExecuteTransaction` request's decoded
/// commands, plus the raw bytes for reference. `preview.summary` is always
/// fully validated by the time this view renders — ``SuiDappProvider``
/// rejects an undecodable or sender-mismatched transaction before any
/// approval prompt, so From is the sender. Gas is shown by ``TransactionFeesView``.
struct SuiTransactionParametersView: View {
    let account: Account
    let preview: SuiTransactionPreview
    let site: String

    var body: some View {
        ParameterSection {
            ParameterRow(String(localized: .commonSite), value: site)
        }

        ParameterSection(String(localized: .commonTransaction)) {
            FromRow(account: account)
            ParameterRow(String(localized: .suiTransactionParametersCommands), value: "\(preview.summary.commandCount)")

            if !moveCallDescriptions.isEmpty {
                ParameterRow(
                    String(localized: .suiTransactionParametersMoveCalls),
                    value: moveCallDescriptions.joined(separator: "\n"),
                    lineLimit: nil
                )
            }
        }

        ParameterBlock(String(localized: .commonRawBytes), text: preview.rawBytes.hexEncoded, maxLines: 6)
    }

    /// Each decoded Move call as `package::module::function`, with the
    /// full package address — on an approval screen the user must be
    /// able to tell exactly which package will run.
    var moveCallDescriptions: [String] {
        preview.summary.moveCalls.map { "\($0.package.string)::\($0.module)::\($0.function)" }
    }
}
