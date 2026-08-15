//
//  SuiAddress.swift
//  WalletKit
//
//  DESIGN SPEC — not generated code. See Walletkit/Docs/Overview.md for
//  module-level notes and architecture.
//

import Foundation

/// A validated Sui address. Distinct from a raw `String` so callers can't
/// accidentally pass an unvalidated, wrong-length, or non-hex value
/// anywhere an address is expected — validity is checked once, at
/// construction, not re-checked at every call site. Conforms to
/// `BlockchainAddress`, the shared surface every chain's address type
/// implements.
public struct SuiAddress: BlockchainAddress {
    /// Raw 32-byte address — the full Blake2b-256 digest of
    /// `flag || publicKey` (see `SuiSigner.address(for:)`), with no
    /// truncation. No `0x` prefix and no checksum casing; unlike
    /// `EthereumAddress`, Sui defines no EIP-55-style mixed-case checksum.
    public let rawBytes: Data

    /// `0x`-prefixed, lowercase 64-hex-character encoding. Computed from
    /// `rawBytes` on every access rather than cached, since it's cheap and
    /// keeps this type's only stored state as the canonical `rawBytes`.
    /// Satisfies `BlockchainAddress.string`.
    public var string: String {
        fatalError("spec only")
    }

    /// Wraps `rawBytes` as a `SuiAddress` — e.g. freshly derived by
    /// `SuiSigner.address(for:)`, or read back from storage. Throws
    /// `.invalidAddress` if `rawBytes.count != 32`; Sui addresses have no
    /// other structural validity to check. Satisfies
    /// `BlockchainAddress.init(rawBytes:) throws`.
    public init(rawBytes: Data) throws {
        fatalError("spec only")
    }

    /// Parses and validates `string` as a Sui address: `0x`-prefixed,
    /// 64 hex characters. Unlike `EthereumAddress.init(string:)`, casing
    /// is never validated — Sui addresses carry no checksum, so any mix
    /// of upper/lowercase hex is accepted as-is. Satisfies
    /// `BlockchainAddress.init(string:) throws`.
    ///
    /// Throws `.invalidAddress` for a missing `0x` prefix, wrong length,
    /// or non-hex characters.
    public init(string: String) throws {
        fatalError("spec only")
    }
}
