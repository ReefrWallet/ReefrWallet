//
//  Account.swift
//  WalletKit
//
//  DESIGN SPEC — not generated code. See Walletkit/Docs/Overview.md for
//  module-level notes and architecture.
//

public protocol AccountProtocol: AnyObject {
    var blockchain: Blockchain { get }
    var derivationPath: DerivationPath { get }
    var curve: Curve { get }
    var source: KeySource { get }
    var publicKey: PublicKey { get }
}

/// An address-capable key handle, sourced from either a software `Wallet`
/// or a connected `HardwareDevice`. This is the type GUI code and future
/// `ChainClient` address derivation hold onto — it carries everything
/// needed to compute an address (curve, path, public key) without callers
/// needing to know whether the key is local or on a physical device.
///
/// `Account` deliberately does *not* expose `sign()`. Software signing
/// still goes through `PrivateKey.sign(message:)` (derive the same
/// `derivationPath` via `Wallet.derive(_:curve:)` to get there). Hardware
/// signing is chain-and-vendor-protocol-specific — Trezor speaks a
/// different wire message per chain (`SignTx` for Bitcoin,
/// `EthereumSignTx` for Ethereum, etc.) — so it's defined per chain module
/// via `HardwareChainSigner` once that module exists, not here.
public final class Account: AccountProtocol {
    public var blockchain: Blockchain { fatalError("spec only") }
    public var derivationPath: DerivationPath { fatalError("spec only") }
    public var curve: Curve { fatalError("spec only") }
    public var source: KeySource { fatalError("spec only") }
    public var publicKey: PublicKey { fatalError("spec only") }
}
