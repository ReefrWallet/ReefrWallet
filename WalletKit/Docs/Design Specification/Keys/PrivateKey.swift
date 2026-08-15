//
//  PrivateKey.swift
//  WalletKit
//
//  DESIGN SPEC — not generated code. See Walletkit/Docs/Overview.md for
//  module-level notes and architecture.
//

import Foundation

public protocol PrivateKeyProtocol: AnyObject {
    var curve: Curve { get }
    var publicKey: PublicKey { get }
    func sign(message: Data) throws -> Data
}

/// Signing happens inside the Rust core. `PrivateKey` intentionally has no
/// raw-bytes getter on the hot path — use `ExtendedKey.serializedPrivate()`
/// or `Wallet.exportBackup()` for the explicit, gated export flows.
public final class PrivateKey: PrivateKeyProtocol {
    public var curve: Curve { fatalError("spec only") }
    public var publicKey: PublicKey { fatalError("spec only") }

    /// Throws `.signingFailed` on curve-specific signing errors.
    public func sign(message: Data) throws -> Data {
        fatalError("spec only")
    }
}
