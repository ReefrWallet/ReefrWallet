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
    /// Color circular logo of the chain's native token (Tokens.xcassets).
    var logoImage: Image {
        Image(logoImageName)
    }

    /// Asset catalog name of the chain's logo.
    var logoImageName: String {
        switch self {
        case .aptos: "aptToken16"
        case .bitcoin: "btcToken16"
        case .cardano: "adaToken16"
        case let .evm(chain): chain.logoImageName
        case .solana: "solToken16"
        case .sui: "suiToken16"
        case .tron: "trxToken16"
        }
    }

    /// Monochrome template network symbol (Networks.xcassets), tinted by the foreground style.
    var networkImage: Image {
        Image(networkImageName)
    }

    /// Asset catalog name of the chain's network symbol.
    var networkImageName: String {
        switch self {
        case .aptos: "aptosNetwork16"
        case .bitcoin: "bitcoinNetwork16"
        case .cardano: "cardanoNetwork16"
        case let .evm(chain): chain.networkImageName
        case .solana: "solanaNetwork16"
        case .sui: "suiNetwork16"
        case .tron: "tronNetwork16"
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
        case .arbitrum: "arbToken16"
        case .avalanche: "avaxToken16"
        case .base: "baseToken16"
        case .bsc: "bnbToken16"
        case .custom: "ethToken16"
        case .ethereum: "ethToken16"
        case .hyperEVM: "hypeToken16"
        case .mantle: "mntToken16"
        case .monad: "monToken16"
        case .optimism: "opToken16"
        case .polygon: "polToken16"
        case .robinhood: "hoodToken16"
        case .unichain: "uniToken16"
        }
    }

    /// Asset catalog name of the chain's network symbol.
    var networkImageName: String {
        switch self {
        case .arbitrum: "arbitrumNetwork16"
        case .avalanche: "avalancheNetwork16"
        case .base: "baseNetwork16"
        case .bsc: "bscNetwork16"
        case .custom: "ethereumNetwork16"
        case .ethereum: "ethereumNetwork16"
        case .hyperEVM: "hyperEVMNetwork16"
        case .mantle: "mantleNetwork16"
        case .monad: "monadNetwork16"
        case .optimism: "optimismNetwork16"
        case .polygon: "polygonNetwork16"
        case .robinhood: "robinhoodNetwork16"
        case .unichain: "unichainNetwork16"
        }
    }
}
