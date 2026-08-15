//
//  HardwareButtonRequest.swift
//  WalletKit
//
//  DESIGN SPEC — not generated code. See Walletkit/Docs/Overview.md for
//  module-level notes and architecture.
//

/// A physical confirmation the user must perform on the device itself
/// (press a button, tap a screen). Nothing for the host to return — just
/// UI to show ("Check your Trezor") until the delegate's operation call
/// resolves or throws `.userRejectedOnDevice`.
public enum HardwareButtonRequest: Equatable {
    case confirmAddress
    case confirmPublicKey
    case confirmTransaction
    case other(description: String)
}
