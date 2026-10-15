//
//  EthereumTypedDataPreviewView.swift
//  Reefr Wallet
//
//  Created by Andrey Yurkevich on 25.09.26.
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import SwiftUI
import WalletKit

/// Shows an `eth_signTypedData_v4` payload's domain, primary type, type
/// definitions, and pretty-printed message JSON. Type definitions are
/// part of the signed payload — they determine how each field in
/// `domain`/`message` is encoded — so they're shown alongside those
/// fields rather than left out of the preview.
struct EthereumTypedDataPreviewView: View {
    let summary: EthereumTypedDataSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Primary type")
                    .style(.small, foreground: .secondary)
                Text(summary.primaryType)
                    .style(.medium)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Types")
                    .style(.small, foreground: .secondary)
                Text(prettyPrinted(summary.typesJSON))
                    .style(.small)
                    .textSelection(.enabled)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Domain")
                    .style(.small, foreground: .secondary)
                Text(prettyPrinted(summary.domainJSON))
                    .style(.small)
                    .textSelection(.enabled)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Message")
                    .style(.small, foreground: .secondary)
                Text(prettyPrinted(summary.messageJSON))
                    .style(.small)
                    .textSelection(.enabled)
            }
        }
    }

    private func prettyPrinted(_ json: String) -> String {
        guard
            let data = json.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data),
            let prettyData = try? JSONSerialization.data(
                withJSONObject: object, options: [.prettyPrinted, .sortedKeys]
            ),
            let prettyString = String(data: prettyData, encoding: .utf8)
        else {
            return json
        }

        return prettyString
    }
}
