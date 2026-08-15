//
//  HardwareDevice.swift
//  WalletKit
//
//  DESIGN SPEC — not generated code. See Walletkit/Docs/Overview.md for
//  module-level notes and architecture.
//

/// A connected hardware device, conforming to `KeyProvider` alongside
/// software key sources — `publicKey(path:curve:)` and `account(_:account:)`
/// work the same way callers expect from software, just backed by a device
/// round trip (and possibly a `HardwareDeviceDelegate` prompt) instead of
/// local derivation. Throws `.deviceLocked`, `.deviceDisconnected`, or
/// `.userRejectedOnDevice` as appropriate.
public protocol HardwareDeviceProtocol: KeyProvider {
    var info: HardwareDeviceInfo { get }
    var isConnected: Bool { get }
    func disconnect() async
}
