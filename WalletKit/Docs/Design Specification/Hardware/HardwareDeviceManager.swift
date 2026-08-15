//
//  HardwareDeviceManager.swift
//  WalletKit
//
//  DESIGN SPEC — not generated code. See Walletkit/Docs/Overview.md for
//  module-level notes and architecture.
//

public protocol HardwareDeviceManagerProtocol: AnyObject {
    /// Enumerates reachable devices across the requested vendors/transports.
    /// USB scanning surfaces devices immediately; Bluetooth scanning may
    /// take a few seconds. Throws `.transportUnavailable` if none of the
    /// requested transports are usable on this platform (e.g. requesting
    /// `.usb` on iOS).
    func scan(vendors: [HardwareVendor], transports: [HardwareTransportKind]) async throws -> [HardwareDeviceInfo]

    /// Opens a session with a previously discovered device. The delegate
    /// is retained for the lifetime of the returned `HardwareDevice`.
    func connect(_ info: HardwareDeviceInfo, delegate: HardwareDeviceDelegate) async throws -> HardwareDevice
}
