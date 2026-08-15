//
//  HardwareVendor.swift
//  WalletKit
//
//  DESIGN SPEC — not generated code. See Walletkit/Docs/Overview.md for
//  module-level notes and architecture.
//

/// Hardware vendors WalletKit knows how to talk to. Trezor ships first;
/// additional cases are added as their own `walletkit-<vendor>` crates land
/// — this enum, and everything in Hardware/, is written to stay
/// vendor-neutral so adding Ledger/Keystone/etc. later doesn't change this
/// file's shape.
public enum HardwareVendor: Equatable, CaseIterable {
    case trezor
}
