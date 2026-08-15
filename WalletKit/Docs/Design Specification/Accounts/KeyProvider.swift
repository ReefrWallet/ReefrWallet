//
//  KeyProvider.swift
//  WalletKit
//
//  DESIGN SPEC — not generated code. See Walletkit/Docs/Overview.md for
//  module-level notes and architecture.
//

/// Common surface for anything that can enumerate accounts and public keys
/// — implemented by `Wallet` (software) and `HardwareDevice` (hardware).
/// Async throughout even though software resolves immediately, so callers
/// can treat both sources identically; hardware calls may suspend for as
/// long as the user takes to respond on the physical device.
public protocol KeyProvider: AnyObject {
    var source: KeySource { get }
    func publicKey(path: DerivationPath, curve: Curve) async throws -> PublicKey
    func account(_ blockchain: Blockchain, account: UInt32) async throws -> Account
}
