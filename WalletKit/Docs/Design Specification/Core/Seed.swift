//
//  Seed.swift
//  WalletKit
//
//  DESIGN SPEC — not generated code. See Walletkit/Docs/Overview.md for
//  module-level notes and architecture.
//

import Foundation

/// A 64-byte BIP39 seed. Prefer deriving keys directly via
/// `masterKey(curve:)` over calling `exportRaw()`, which exists only for
/// advanced/backup flows and hands raw bytes across the FFI boundary.
public protocol SeedProtocol: AnyObject {
    /// Derives the master `ExtendedKey` for the requested curve/scheme.
    /// Throws `.unsupportedCurve` for curves the core doesn't implement yet.
    func masterKey(curve: Curve) throws -> ExtendedKey

    /// Raw 64-byte seed. Sensitive — treat as short-lived, don't log it.
    func exportRaw() -> Data
}
