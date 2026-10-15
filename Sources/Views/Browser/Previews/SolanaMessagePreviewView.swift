//
//  SolanaMessagePreviewView.swift
//  Reefr Wallet
//
//  Created by Andrey Yurkevich on 30.09.26.
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import Foundation
import SwiftUI

/// Shows a `solana:signMessage` message as UTF-8 text, or hex if the
/// bytes aren't valid UTF-8 — mirrors ``SuiPersonalPreviewView``.
struct SolanaMessagePreviewView: View {
    let message: Data

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Message")
                .style(.small, foreground: .secondary)

            Text(displayText)
                .style(.medium)
                .textSelection(.enabled)
        }
    }

    private var displayText: String {
        if let text = String(data: message, encoding: .utf8) {
            return text
        }

        return "0x" + message.map { String(format: "%02x", $0) }.joined()
    }
}
