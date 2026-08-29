//
//  BlockchainTransactionBuilderOptions.swift
//  WalletKit
//
//  Created by Andrey Yurkevich on 29/08/2026.
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import Foundation

/// A flag passed in the `options` array of
/// ``BlockchainTransactionBuilderProtocol/buildTransfer(sender:recipient:amount:token:options:)``.
/// Pass `[]` for the chain's default behaviour; add flags to the array to
/// alter it. Flags not meaningful for a particular blockchain are ignored.
///
/// Example — force a legacy EIP-155 transaction on Ethereum:
/// ```swift
/// let txBytes = try await builder.buildTransfer(
///     sender: sender, recipient: recipient, amount: amount, token: nil,
///     options: [.legacyEip155]
/// )
/// ```
public enum BlockchainTransactionBuilderOptions: Sendable {
    /// Build a legacy EIP-155 transaction instead of the default EIP-1559
    /// (type-2) transaction. Only meaningful for Ethereum — Sui and future
    /// blockchains ignore this.
    case legacyEip155
}
