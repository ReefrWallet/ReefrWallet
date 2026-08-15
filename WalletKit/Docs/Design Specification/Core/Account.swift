//
//  Account.swift
//  WalletKit
//
//  DESIGN SPEC — not generated code. See Walletkit/Docs/Overview.md for
//  module-level notes and architecture.
//

/// An address-capable key handle, sourced from either a software key
/// source or a connected `HardwareDevice`. This is the type GUI code and
/// `Signer` address derivation/signing hold onto — it carries
/// everything needed to compute an address or route a signing request
/// (curve, path, public key, source) without callers needing to know
/// whether the key is local or on a physical device.
///
/// `Account` deliberately does *not* expose `sign()` itself — that lives
/// one level up, on `Signer.sign(transaction:account:)`, which
/// takes an `Account` rather than being a method on it, so a single
/// signing entry point can dispatch on `account.source` (software vs.
/// hardware) without `Account` itself needing chain-specific logic.
/// Software signing under the hood still goes through
/// `PrivateKey.sign(message:)` (derive the same `derivationPath` via
/// `ExtendedKey.derive(_:)` from the seed's master key to get there);
/// hardware signing is
/// chain-and-vendor-protocol-specific — Trezor speaks a different wire
/// message per chain (`SignTx` for Bitcoin, `EthereumSignTx` for Ethereum,
/// etc.) — so each `Signer` conformer routes it through its own
/// `HardwareSigner` conformer internally.
public struct Account {
    let blockchain: Blockchain
    let derivationPath: DerivationPath
    let curve: Curve
    let source: KeySource
    let publicKey: PublicKey
}
