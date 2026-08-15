//
//  Seed.swift
//  WalletKit
//
//  DESIGN SPEC — not generated code. See Walletkit/Docs/Overview.md for
//  module-level notes and architecture.
//

import Foundation

public protocol SeedProtocol: AnyObject {
    func masterKey(curve: Curve) throws -> ExtendedKey
    func exportRaw() -> Data
}

/// A 64-byte BIP39 seed. Prefer deriving keys directly via
/// `masterKey(curve:)` over calling `exportRaw()`, which exists only for
/// advanced/backup flows and hands raw bytes across the FFI boundary.
public final class Seed: SeedProtocol {
    /// Derives the master `ExtendedKey` for the requested curve/scheme.
    /// Throws `.unsupportedCurve` for curves the core doesn't implement yet.
    public func masterKey(curve: Curve) throws -> ExtendedKey {
        fatalError("spec only")
    }

    /// Raw 64-byte seed. Sensitive — treat as short-lived, don't log it.
    public func exportRaw() -> Data {
        fatalError("spec only")
    }
}
