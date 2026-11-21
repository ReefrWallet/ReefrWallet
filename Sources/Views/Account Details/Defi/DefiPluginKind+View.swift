//
//  DefiPluginKind+View.swift
//  Reefr Wallet
//
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import SwiftUI
import WalletKit

extension DefiPluginKind {
    /// The plugin's own view of its stored records.
    @MainActor
    @ViewBuilder
    func section(_ positions: [DefiPosition], blockchain: Blockchain) -> some View {
        switch self {
        case .uniswapV3:
            UniswapV3Section(positions: positions, blockchain: blockchain)
        }
    }
}
