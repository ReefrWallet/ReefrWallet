//
//  NFT+Sending.swift
//  Reefr Wallet
//
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import Foundation
import WalletKit

extension KeyStore {
    /// Whether this key store can sign transactions on `blockchain`. Trezor
    /// has no Aptos or Sui support (ADR-029); local Cardano signing needs the
    /// BIP-39 entropy.
    func canSignTransactions(on blockchain: Blockchain) -> Bool {
        switch kind {
        case .watchOnly:
            return false
        case .local:
            if case .cardano = blockchain {
                return sealedEntropy != nil
            }

            return true
        case .trezor:
            switch blockchain {
            case .bitcoin, .cardano, .evm, .solana, .tron:
                return true
            case .aptos, .sui, .ton:
                return false
            }
        }
    }
}

extension NFT {
    /// Why Send is unavailable for this NFT, or `nil` if it can be sent.
    func sendBlockReason(keyStore: KeyStore, blockchain: Blockchain) -> LocalizedStringResource? {
        if !keyStore.canSignTransactions(on: blockchain) {
            return keyStore.kind == .watchOnly ? .nftsWatchOnly : .nftsKeyStoreUnsupported
        }

        if !isTransferable {
            return .nftsNotTransferable
        }

        if sendState == .unconfirmed {
            return .nftsUnconfirmedSend
        }

        return quantity > 0 ? nil : .nftsNotTransferable
    }

    func canSend(keyStore: KeyStore, blockchain: Blockchain) -> Bool {
        sendBlockReason(keyStore: keyStore, blockchain: blockchain) == nil
    }
}
