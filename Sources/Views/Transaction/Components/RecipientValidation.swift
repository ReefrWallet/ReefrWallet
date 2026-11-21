//
//  RecipientValidation.swift
//  Reefr Wallet
//
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import WalletKit

extension Blockchain {
    /// Whether `text` is a valid recipient address on this chain.
    ///
    /// Exhaustive on purpose: a `default` that rejects everything would
    /// silently disable every send form for a newly supported chain.
    func isValidRecipient(_ text: String) -> Bool {
        do {
            switch self {
            case .aptos:
                _ = try AptosAddress(string: text)
            case let .bitcoin(network):
                _ = try BitcoinDescriptor(address: text, network: network)
            case let .cardano(network):
                _ = try CardanoAddress(string: text, network: network)
            case .evm:
                _ = try EthereumAddress(string: text)
            case .solana:
                _ = try SolanaAddress(string: text)
            case .sui:
                _ = try SuiAddress(string: text)
            case let .ton(network):
                try TonAddress(string: text).validate(for: network)
            case .tron:
                _ = try TronAddress(string: text)
            }

            return true
        } catch {
            return false
        }
    }

    /// The receiver field's placeholder, e.g. "0x…" or "bc1…".
    var recipientPrompt: String {
        switch self {
        case .aptos, .evm, .sui: "0x…"
        case .bitcoin: "bc1…"
        case .cardano: "addr1…"
        case .solana: "Address"
        case .ton: "UQ…"
        case .tron: "T…"
        }
    }
}
