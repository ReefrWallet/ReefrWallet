//
//  Blockchain+Staking.swift
//  Reefr Wallet
//
//  Created by Andrey Yurkevich on 06.11.26.
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import WalletKit

extension Blockchain {
    /// Chains with a Staking tab.
    var supportsStaking: Bool {
        switch self {
        case .cardano, .solana, .sui, .tron: true
        default: false
        }
    }
}
