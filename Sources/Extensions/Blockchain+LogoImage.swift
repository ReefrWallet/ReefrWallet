//
//  Blockchain+LogoImage.swift
//  ReefrWallet
//
//  Created by Andrey Yurkevich on 12/10/2026.
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import SwiftUI
import WalletKit

extension Blockchain {
    var logoImage: Image {
        Image(logoImageName)
    }

    /// Asset catalog name of the chain's logo.
    var logoImageName: String {
        switch self {
        case .aptos: "apt-logo"
        case .bitcoin: "btc-logo"
        case let .evm(chain): chain.logoImageName
        case .tron: "trx-logo"
        case .solana: "sol-logo"
        case .cardano: "ada-logo"
        case .sui: "sui-logo"
        }
    }
}

extension EVMBlockchain {
    var logoImage: Image {
        Image(logoImageName)
    }

    /// Asset catalog name of the chain's logo.
    var logoImageName: String {
        switch self {
        case .arbitrum: "arb-logo"
        case .avalanche: "avax-logo"
        case .base: "base-logo"
        case .bsc: "bsc-logo"
        case .custom: "eth-logo"
        case .ethereum: "eth-logo"
        case .hyperEVM: "hype-logo"
        case .mantle: "mnt-logo"
        case .monad: "mon-logo"
        case .optimism: "op-logo"
        case .polygon: "pol-logo"
        case .robinhood: "hood-logo"
        case .unichain: "uni-logo"
        }
    }
}
