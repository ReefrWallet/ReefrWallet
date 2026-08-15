//
//  BlockchainAddress.swift
//  WalletKit
//
//  DESIGN SPEC — not generated code. See Walletkit/Docs/Overview.md for
//  module-level notes and architecture.
//

import Foundation

/// Common surface every chain's address type conforms to — implemented by
/// `EthereumAddress` today, and by each future `walletkit-<chain>`'s own
/// address type (a Bitcoin base58check/bech32 address, a Solana base58
/// address, ...) as chain clients are added. Lets chain-agnostic code
/// (persistence, an address-book UI, QR scanning) work against
/// `any BlockchainAddress` without knowing which chain it's for, while each
/// `BlockchainClient` still returns its own concrete `Address` type (see
/// `BlockchainClient`) for call sites that need chain-specific behavior.
public protocol BlockchainAddress: Equatable {
    /// Canonical string encoding for this chain — checksummed hex for
    /// Ethereum, base58check or bech32 for Bitcoin, etc. Whatever a wallet
    /// UI would show as "the address" and a user would copy/paste.
    var string: String { get }

    /// Canonical raw byte encoding for this chain.
    var rawBytes: Data { get }

    /// Parses and validates `string` in this chain's canonical string
    /// format. Throws `.invalidAddress` for malformed input.
    init(string: String) throws

    /// Wraps `rawBytes` as this chain's address type. Throws
    /// `.invalidAddress` if `rawBytes` isn't a structurally valid encoding
    /// for this chain (e.g. the wrong length).
    init(rawBytes: Data) throws
}
