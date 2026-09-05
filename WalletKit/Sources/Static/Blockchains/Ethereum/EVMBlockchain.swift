//
//  EVMBlockchain.swift
//  WalletKit
//
//  Created by Andrey Yurkevich on 25/08/2026.
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import SwiftUI

public enum EVMBlockchain: Equatable, Hashable, Codable, Sendable {
    case arbitrum(Network)
    case bsc(Network)
    case ethereum(Network)
    case custom(UInt64)

    public init(chainId: UInt64) {
        switch chainId {
        case 0x1: self = .ethereum(.mainnet)
        case 0xaa36a7: self = .ethereum(.testnet)
        case 0xa4b1: self = .arbitrum(.mainnet)
        case 0x66eee: self = .arbitrum(.testnet)
        case 0x38: self = .bsc(.mainnet)
        case 0x61: self = .bsc(.testnet)
        default: self = .custom(chainId)
        }
    }
}

public extension EVMBlockchain {
    enum Network: Equatable, Hashable, Codable, Sendable {
        case mainnet
        case testnet

        var name: String {
            switch self {
            case .mainnet: "Mainnet"
            case .testnet: "Testnet"
            }
        }
    }
}

public extension EVMBlockchain {
    static var allMainnets: [WKBlockchain] {
        [
            .evm(.arbitrum(.mainnet)),
            .evm(.bsc(.mainnet)),
            .evm(.ethereum(.mainnet)),
            .evm(.custom(0))
        ]
    }

    var allNetworks: [WKBlockchain] {
        switch self {
        case .arbitrum: [.evm(.arbitrum(.mainnet)), .evm(.arbitrum(.testnet))]
        case .bsc: [.evm(.bsc(.mainnet)), .evm(.bsc(.testnet))]
        case .ethereum: [.evm(.ethereum(.mainnet)), .evm(.ethereum(.testnet))]
        case let .custom(chainId): [.evm(.custom(chainId))]
        }
    }

    var chainId: UInt64 {
        switch self {
        case let .arbitrum(network):
            switch network {
            case .mainnet: 0xa4b1
            case .testnet: 0x66eee
            }
        case let .bsc(network):
            switch network {
            case .mainnet: 0x38
            case .testnet: 0x61
            }
        case let .ethereum(network):
            switch network {
            case .mainnet: 0x1
            case .testnet: 0xaa36a7
            }
        case let .custom(chainId):
            chainId
        }
    }

    var isMainnet: Bool {
        switch self {
        case let .arbitrum(network):
            network == .mainnet
        case let .bsc(network):
            network == .mainnet
        case let .ethereum(network):
            network == .mainnet
        case .custom:
            true
        }
    }

    var name: String {
        switch self {
        case .arbitrum:
            "Arbitrum"
        case .bsc:
            "BSC"
        case .custom:
            "Custom EVM"
        case .ethereum:
            "Ethereum"
        }
    }

    var nativeToken: TokenInfo {
        switch self {
        case .arbitrum: TokenInfo(decimals: 18, name: "Arbitrum Ether", isNative: true, symbol: "ETH")
        case .bsc: TokenInfo(decimals: 8, name: "Binance Coin", isNative: true, symbol: "BNB")
        case .ethereum: TokenInfo(decimals: 18, name: "Ether", isNative: true, symbol: "ETH")

        case let .custom(chainId): TokenInfo(
            decimals: 18,
            name: "EVM Chain \(chainId) Ether",
            isNative: true,
            symbol: "ETH")
        }
    }

    var logoImage: Image {
        switch self {
        case .arbitrum:
            Image("arb-logo")
        case .bsc:
            Image("bsc-logo")
        case .custom:
            Image("eth-logo")
        case .ethereum:
            Image("eth-logo")
        }
    }

    var networkName: String {
        switch self {
        case let .arbitrum(network):
            "Arbitrum \(network.name)"
        case let .bsc(network):
            "BSC \(network.name)"
        case let .custom(chainId):
            "Custom EVM" + (chainId > 0 ? " (id \(chainId))" : "")
        case let .ethereum(network):
            "Ethereum \(network.name)"
        }
    }

    var rpcURL: URL {
        switch self {
        case let .arbitrum(network):
            switch network {
            case .mainnet: URL(string: "https://arbitrum-one-rpc.publicnode.com")!
            case .testnet: URL(string: "https://arbitrum-sepolia-rpc.publicnode.com")!
            }
        case let .bsc(network):
            switch network {
            case .mainnet: URL(string: "https://bsc-rpc.publicnode.com")!
            case .testnet: URL(string: "https://bsc-testnet-rpc.publicnode.com")!
            }
        case let .ethereum(network):
            switch network {
            case .mainnet: URL(string: "https://ethereum-rpc.publicnode.com")!
            case .testnet: URL(string: "https://ethereum-sepolia-rpc.publicnode.com")!
            }
        case .custom:
            URL(string: "https://localhost")!
        }
    }

    func isSameBlockchain(as other: EVMBlockchain) -> Bool {
        switch (self, other) {
        case (.arbitrum, .arbitrum), (.bsc, .bsc), (.ethereum, .ethereum):
            true
        case let (.custom(chainId), .custom(otherChainId)):
            chainId == otherChainId
        default:
            false
        }
    }
}
