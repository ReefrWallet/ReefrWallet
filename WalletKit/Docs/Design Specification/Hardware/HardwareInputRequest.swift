//
//  HardwareInputRequest.swift
//  WalletKit
//
//  DESIGN SPEC — not generated code. See Walletkit/Docs/Overview.md for
//  module-level notes and architecture.
//

/// A host-side input the device needs mid-operation. Trezor supports both
/// on-device PIN/passphrase entry (nothing to do here but wait) and
/// host-entered PIN (via a scrambled matrix shown on the device screen) —
/// `.pin`/`.passphrase` only fire for the host-entry case.
public enum HardwareInputRequest: Equatable {
    case pin(attempt: UInt32)
    case passphrase
}
