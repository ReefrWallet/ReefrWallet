//
//  DappNamespace.swift
//  Reefr Wallet
//
//  Created by Andrey Yurkevich on 25.09.26.
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import WalletKit

/// One wallet-provider namespace a dapp can talk to — `window.ethereum`
/// for Ethereum, Wallet Standard for Sui/Solana, TronLink-style
/// `window.tronLink`/`window.tronWeb` for Tron, CIP-30 `window.cardano` for
/// Cardano. Bitcoin plugs in the same way later: chain-agnostic
/// bridge/session/approval code dispatches on this case, while only the
/// namespace's own `DappProvider` and JS files know anything chain-specific.
enum DappNamespace: String, CaseIterable, Sendable {
    case aptos
    case cardano
    case ethereum
    case solana
    case sui
    case tron
    // Later: case bitcoin.

    /// Third-party JS libraries this namespace's provider scripts depend
    /// on — `Resources/Browser/vendor/<name>.js` for each, injected before
    /// ``providerScriptNames``. Each is wrapped so it's only evaluated on
    /// first use and never touches page globals (ADR-030, ADR-032).
    var libraryScriptNames: [String] {
        switch self {
        case .aptos, .cardano, .ethereum, .solana: []
        case .sui: ["sui-sdk"]
        case .tron: ["tronweb"]
        }
    }

    /// The JS resources this namespace's provider script(s) are bundled
    /// under — `Resources/Browser/providers/<name>.js` for each. A
    /// namespace can inject more than one script (Ethereum injects both
    /// its EIP-1193 provider and an additive Wallet Standard wrapper
    /// around the same native provider).
    var providerScriptNames: [String] {
        switch self {
        case .aptos: ["aptos"]
        case .cardano: ["cardano"]
        case .ethereum: ["ethereum", "ethereum-wallet-standard"]
        case .solana: ["solana", "solana-legacy"]
        case .sui: ["sui"]
        case .tron: ["tron"]
        }
    }

    /// Everything this namespace injects, in load order: its vendored
    /// libraries, then its own provider scripts.
    var scriptNames: [String] {
        libraryScriptNames + providerScriptNames
    }

    /// Whether `blockchain` belongs to this namespace's chain family —
    /// used to filter the browser's per-namespace account picker.
    func matches(_ blockchain: Blockchain) -> Bool {
        switch self {
        case .aptos:
            if case .aptos = blockchain {
                return true
            }

            return false
        case .cardano:
            if case .cardano = blockchain {
                return true
            }

            return false
        case .ethereum:
            if case .evm = blockchain {
                return true
            }

            return false
        case .solana:
            if case .solana = blockchain {
                return true
            }

            return false
        case .sui:
            if case .sui = blockchain {
                return true
            }

            return false
        case .tron:
            if case .tron = blockchain {
                return true
            }

            return false
        }
    }

    /// The namespace `blockchain` belongs to, or `nil` if no namespace
    /// supports it yet — the single source of truth for whether a chain
    /// is browser-supported.
    static func namespace(for blockchain: Blockchain) -> DappNamespace? {
        allCases.first { $0.matches(blockchain) }
    }
}
