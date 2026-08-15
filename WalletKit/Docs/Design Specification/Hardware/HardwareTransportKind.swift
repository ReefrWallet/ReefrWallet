//
//  HardwareTransportKind.swift
//  WalletKit
//
//  DESIGN SPEC — not generated code. See Walletkit/Docs/Overview.md for
//  module-level notes and architecture.
//

/// How WalletKit is talking to the physical device. Relevant to callers
/// because platform support differs sharply by transport:
/// - `.usb`: full support on macOS. Not usable from iOS apps for
///   non-MFi-certified accessories — which is all Trezor models except
///   Safe 7 — so USB-connected Trezors are macOS-only for signing today.
/// - `.bluetooth`: works on macOS and iOS. Currently only Trezor Safe 7
///   supports it; older/other models don't have a Bluetooth radio.
/// - `.qrAirGap`: camera-based, offline signing (scan an unsigned
///   transaction QR, device signs, scan the signed result back). No
///   USB/BLE entitlements needed, works identically on iOS and macOS.
///   Not used by Trezor; kept here for vendors that do support it.
public enum HardwareTransportKind: Equatable, CaseIterable {
    case usb
    case bluetooth
    case qrAirGap
}
