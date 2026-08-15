//
//  KeySource.swift
//  WalletKit
//
//  DESIGN SPEC — not generated code. See Walletkit/Docs/Overview.md for
//  module-level notes and architecture.
//

/// Identifies where a key/account's material actually lives. Surfaced on
/// `Account` and in the GUI (e.g. to badge an address "Trezor" vs. local)
/// so nothing downstream needs its own software/hardware branching.
public enum KeySource: Equatable {
    case software
    case hardware(HardwareDeviceInfo)
}
