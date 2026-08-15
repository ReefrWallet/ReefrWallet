//
//  EthereumAddress.swift
//  WalletKit
//
//  DESIGN SPEC — not generated code. See Walletkit/Docs/Overview.md for
//  module-level notes and architecture.
//

import Foundation

/// A validated Ethereum address. Distinct from a raw `String` so callers
/// can't accidentally pass an unvalidated, wrong-length, or non-hex value
/// anywhere an address is expected — validity is checked once, at
/// construction, not re-checked at every call site. Conforms to
/// `BlockchainAddress`, the shared surface every chain's address type
/// implements.
public struct EthereumAddress: BlockchainAddress {
    /// Raw 20-byte address. No `0x` prefix, no checksum casing — checksum
    /// casing is a display-time property of the hex encoding, not part of
    /// the address's identity, so it isn't tracked as separate state here.
    public let rawBytes: Data

    /// EIP-55 mixed-case checksummed `0x`-prefixed hex encoding. Computed
    /// from `rawBytes` on every access rather than cached, since it's cheap
    /// (one Keccak-256 hash of 40 hex characters) and keeps this type's
    /// only stored state as the canonical `rawBytes`. Satisfies
    /// `BlockchainAddress.string`.
    public var string: String {
        fatalError("spec only")
    }

    /// Ethereum-specific alias for `string`, kept as the more descriptive
    /// name for call sites that already know they're holding an
    /// `EthereumAddress` rather than an `any BlockchainAddress`.
    public var checksummed: String { string }

    /// Wraps `rawBytes` as an `EthereumAddress` — e.g. freshly derived from
    /// a public key by `EthereumClient.address(for:)`, or read back
    /// from storage. Throws `.invalidAddress` if `rawBytes.count != 20`;
    /// Ethereum addresses have no other structural validity to check (any
    /// 20 bytes are otherwise a well-formed address). Satisfies
    /// `BlockchainAddress.init(rawBytes:) throws`.
    public init(rawBytes: Data) throws {
        fatalError("spec only")
    }

    /// Parses and validates `string` as an Ethereum address. Accepts
    /// `0x`-prefixed, 40-hex-character input in any case — all-lowercase,
    /// all-uppercase, or already EIP-55 checksummed. Satisfies
    /// `BlockchainAddress.init(string:) throws`.
    ///
    /// Throws `.invalidAddress` for malformed input: missing `0x` prefix,
    /// wrong length, non-hex characters, or a mixed-case input whose
    /// casing fails EIP-55 validation.
    ///
    /// An all-lowercase or all-uppercase input is accepted as-is (it simply
    /// carries no checksum to validate); a mixed-case input is held to the
    /// EIP-55 checksum and rejected (throws) if it doesn't match.
    public init(string: String) throws {
        fatalError("spec only")
    }
}
