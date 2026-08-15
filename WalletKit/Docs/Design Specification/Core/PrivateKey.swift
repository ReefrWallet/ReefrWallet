//
//  PrivateKey.swift
//  WalletKit
//
//  DESIGN SPEC — not generated code. See Walletkit/Docs/Overview.md for
//  module-level notes and architecture.
//

import Foundation

/// Signing happens inside the Rust core. `PrivateKey` intentionally has no
/// raw-bytes getter on the hot path — use `ExtendedKey.serializedPrivate()`
/// for the explicit, gated export flow.
public protocol PrivateKeyProtocol: AnyObject {
    var curve: Curve { get }
    var publicKey: PublicKey { get }
    /// Throws `.signingFailed` on curve-specific signing errors.
    func sign(message: Data) throws -> Data
}
