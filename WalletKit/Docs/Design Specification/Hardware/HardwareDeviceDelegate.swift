//
//  HardwareDeviceDelegate.swift
//  WalletKit
//
//  DESIGN SPEC — not generated code. See Walletkit/Docs/Overview.md for
//  module-level notes and architecture.
//

/// Implemented by the host app. WalletKit calls back into Swift mid-
/// operation whenever a connected device needs host input or physical
/// confirmation. On the Rust side this is a UniFFI callback interface
/// (a Swift-implemented trait object Rust holds and calls into), which is
/// why every method here is `async` — Rust suspends the in-flight device
/// operation until the app responds.
public protocol HardwareDeviceDelegate: AnyObject {
    /// Return nil to cancel the in-flight operation.
    func hardwareDevice(_ device: HardwareDevice, needsInput request: HardwareInputRequest) async -> String?
    func hardwareDevice(_ device: HardwareDevice, waitingForConfirmation request: HardwareButtonRequest) async
    func hardwareDeviceDidDisconnect(_ device: HardwareDevice)
}
