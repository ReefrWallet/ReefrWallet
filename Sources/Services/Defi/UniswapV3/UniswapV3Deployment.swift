//
//  UniswapV3Deployment.swift
//  Reefr Wallet
//
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import WalletKit

/// A chain's Uniswap V3 factory and NonfungiblePositionManager.
struct UniswapV3Deployment: Sendable {
    /// The position manager's creation block; the floor of mint searches.
    let deploymentBlock: UInt64
    let factory: EthereumAddress
    let positionManager: EthereumAddress

    /// For compile-time constant addresses; traps on an invalid one.
    init(factory: String, positionManager: String, deploymentBlock: UInt64) {
        // swiftlint:disable force_try
        self.factory = try! EthereumAddress(string: factory)
        self.positionManager = try! EthereumAddress(string: positionManager)
        // swiftlint:enable force_try
        self.deploymentBlock = deploymentBlock
    }

    static func deployment(for blockchain: Blockchain) -> Self? {
        guard case let .evm(chain) = blockchain else {
            return nil
        }

        return all[chain.chainId]
    }

    /// By chain id.
    static let all: [UInt64: Self] = [
        // Ethereum
        1: Self(
            factory: "0x1f98431c8ad98523631ae4a59f267346ea31f984",
            positionManager: "0xc36442b4a4522e871399cd717abdd847ab11fe88",
            deploymentBlock: 12_369_651
        ),
        // Optimism
        10: Self(
            factory: "0x1f98431c8ad98523631ae4a59f267346ea31f984",
            positionManager: "0xc36442b4a4522e871399cd717abdd847ab11fe88",
            deploymentBlock: 0
        ),
        // BSC
        56: Self(
            factory: "0xdb1d10011ad0ff90774d0c6bb92e5c5c8b4461f7",
            positionManager: "0x7b8a01b39d58278b5de7e48c8449c9f4f5170613",
            deploymentBlock: 26_324_045
        ),
        // Unichain
        130: Self(
            factory: "0x1f98400000000000000000000000000000000003",
            positionManager: "0x943e6e07a7e8e791dafc44083e54041d743c46e9",
            deploymentBlock: 294_152
        ),
        // Polygon
        137: Self(
            factory: "0x1f98431c8ad98523631ae4a59f267346ea31f984",
            positionManager: "0xc36442b4a4522e871399cd717abdd847ab11fe88",
            deploymentBlock: 22_760_586
        ),
        // Base
        8_453: Self(
            factory: "0x33128a8fc17869897dce68ed026d694621f6fdfd",
            positionManager: "0x03a520b32c04bf3beef7beb72e919cf822ed34f1",
            deploymentBlock: 1_371_714
        ),
        // Arbitrum
        42_161: Self(
            factory: "0x1f98431c8ad98523631ae4a59f267346ea31f984",
            positionManager: "0xc36442b4a4522e871399cd717abdd847ab11fe88",
            deploymentBlock: 173
        ),
        // Avalanche
        43_114: Self(
            factory: "0x740b1c1de25031c31ff4fc9a62f554a55cdc1bad",
            positionManager: "0x655c406ebfa14ee2006250925e54ec43ad184f8b",
            deploymentBlock: 27_833_025
        ),
        // Sepolia
        11_155_111: Self(
            factory: "0x0227628f3f023bb0b980b67d528571c95c6dac1c",
            positionManager: "0x1238536071e1c677a632429e3655c799b22cda52",
            deploymentBlock: 3_518_286
        )
    ]
}
