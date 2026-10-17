//
//  WalletConnectChain.swift
//  Reefr Wallet
//
//  Created by Andrey Yurkevich on 17.10.26.
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import WalletKit

/// CAIP-2 ↔ ``Blockchain``/``DappNamespace`` mapping and the methods each
/// namespace advertises to WalletConnect dapps.
enum WalletConnectChain {
    static func blockchain(caip2: String) -> Blockchain? {
        let parts = caip2.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2 else {
            return nil
        }

        let reference = parts[1]

        switch parts[0] {
        case "aptos":
            switch reference {
            case "1": return .aptos(.mainnet)
            case "2": return .aptos(.testnet)
            default: return nil
            }

        case "eip155":
            return UInt64(reference).map { .evm(EVMBlockchain(chainId: $0)) }
        case "solana":
            switch reference {
            case "4uhcVJyU9pJkvQyS88uRDiswHXSCkY3z": return .solana(.testnet)
            case "5eykt4UsFv8P8NJdTREpY1vzqKqZKvdp": return .solana(.mainnet)
            case "EtWTRABZaYq6iMfeYKouRu166VU2xqa1": return .solana(.devnet)
            default: return nil
            }

        case "sui":
            switch reference {
            case "mainnet": return .sui(.mainnet)
            case "testnet": return .sui(.testnet)
            default: return nil
            }

        case "tron":
            switch reference {
            case "0x2b6653dc": return .tron(.mainnet)
            case "0xcd8690dc": return .tron(.testnet)
            default: return nil
            }

        default:
            return nil
        }
    }

    static func caip2(for blockchain: Blockchain) -> String? {
        switch blockchain {
        case let .aptos(network):
            network == .mainnet ? "aptos:1" : "aptos:2"
        case let .evm(chain):
            "eip155:\(chain.chainId)"
        case let .solana(network):
            switch network {
            case .devnet: "solana:EtWTRABZaYq6iMfeYKouRu166VU2xqa1"
            case .mainnet: "solana:5eykt4UsFv8P8NJdTREpY1vzqKqZKvdp"
            case .testnet: "solana:4uhcVJyU9pJkvQyS88uRDiswHXSCkY3z"
            }

        case let .sui(network):
            network == .mainnet ? "sui:mainnet" : "sui:testnet"
        case let .tron(network):
            network == .mainnet ? "tron:0x2b6653dc" : "tron:0xcd8690dc"
        case .bitcoin, .cardano:
            nil
        }
    }

    static func dappNamespace(caip2: String) -> DappNamespace? {
        blockchain(caip2: caip2).flatMap { DappNamespace.namespace(for: $0) }
    }

    static let events: [DappNamespace: [String]] = [
        .aptos: [],
        .ethereum: ["accountsChanged", "chainChanged"],
        .solana: [],
        .sui: [],
        .tron: []
    ]

    static let methods: [DappNamespace: [String]] = [
        .aptos: ["aptos_signMessage", "aptos_signTransaction"],
        .ethereum: ["eth_sendTransaction", "eth_signTypedData_v4", "personal_sign"],
        .solana: ["solana_signAndSendTransaction", "solana_signMessage", "solana_signTransaction"],
        .sui: ["sui_signAndExecuteTransaction", "sui_signPersonalMessage", "sui_signTransaction"],
        .tron: ["tron_signMessage", "tron_signTransaction"]
    ]
}
