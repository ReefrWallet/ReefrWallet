//
//  RevertLendDeployment.swift
//  Reefr Wallet
//
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import Foundation
import WalletKit

/// A chain's Revert Lend V3Vault for Uniswap V3 collateral. See ADR-075.
struct RevertLendDeployment: Sendable {
    /// The vault's lent and borrowed token (USDC).
    let asset: EthereumAddress
    let interestRateModel: EthereumAddress
    let vault: EthereumAddress

    /// For compile-time constant addresses; traps on an invalid one.
    init(asset: String, interestRateModel: String, vault: String) {
        // swiftlint:disable force_try
        self.asset = try! EthereumAddress(string: asset)
        self.interestRateModel = try! EthereumAddress(string: interestRateModel)
        self.vault = try! EthereumAddress(string: vault)
        // swiftlint:enable force_try
    }

    static func deployment(for blockchain: Blockchain) -> Self? {
        guard case let .evm(chain) = blockchain else {
            return nil
        }

        return all[chain.chainId]
    }

    /// By chain id; each vault's position manager is that chain's Uniswap V3 one.
    static let all: [UInt64: Self] = [
        // Ethereum
        1: Self(
            asset: "0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48",
            interestRateModel: "0xb50dafe03fee68595ab2baad3c16f899421f063b",
            vault: "0xa2754543f69dc036764bbfad16d2a74f5cd15667"
        ),
        // Base
        8_453: Self(
            asset: "0x833589fcd6edb6e08f4c7c32d4f71b54bda02913",
            interestRateModel: "0xd0524a77c8e2bd22b1f57268fd6bea1973ac7927",
            vault: "0x36aeae0e411a1e28372e0d66f02e57744ebe7599"
        ),
        // Arbitrum
        42_161: Self(
            asset: "0xaf88d065e77c8cc2239327c5edb3a432268e5831",
            interestRateModel: "0x18616c0a8389a2cabf596f91d3e6ccc626e58997",
            vault: "0x74e6afef5705beb126c6d3bf46f8fad8f3e07825"
        )
    ]
}
