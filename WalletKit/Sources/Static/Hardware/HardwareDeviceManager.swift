//
//  HardwareDeviceManager.swift
//  WalletKit
//
//  Created by Andrey Yurkevich on 20/08/2026.
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

/// Discovers and connects to hardware wallets.
public protocol HardwareDeviceManagerProtocol: AnyObject {
    /// Scans for connected/reachable hardware devices.
    ///
    /// - Parameters:
    ///   - vendors: Which manufacturers to look for.
    ///   - transports: Which transports to scan over. Must be non-empty.
    /// - Returns: Info for every discovered device.
    func scan(vendors: [HardwareVendor], transports: [HardwareTransportKind]) async throws -> [HardwareDeviceInfo]

    /// Connects to a previously discovered device.
    ///
    /// - Parameters:
    ///   - info: The device to connect to, as returned by ``scan``.
    ///   - delegate: The delegate to relay input/confirmation requests and
    ///     disconnection events to.
    /// - Returns: The connected device.
    func connect(_ info: HardwareDeviceInfo, delegate: HardwareDeviceDelegate) async throws -> HardwareDevice
}

/// Discovers and connects to hardware wallets.
///
/// - Note: No real transport (USB/Bluetooth) integration exists yet —
///   ``scan(vendors:transports:)`` always succeeds with an empty result,
///   and ``connect(_:delegate:)`` always throws
///   ``WalletKitError/deviceNotFound``.
public final class HardwareDeviceManager: HardwareDeviceManagerProtocol {
    public init() {}

    /// Scans for connected/reachable hardware devices.
    ///
    /// - Parameters:
    ///   - vendors: Which manufacturers to look for. Defaults to every
    ///     supported vendor.
    ///   - transports: Which transports to scan over. Must be non-empty.
    ///     Defaults to USB and Bluetooth.
    /// - Returns: Info for every discovered device. Currently always empty
    ///   — see the type-level note.
    /// - Throws: ``WalletKitError/transportUnavailable(reason:)`` if
    ///   `transports` is empty.
    public func scan(
        vendors: [HardwareVendor] = HardwareVendor.allCases,
        transports: [HardwareTransportKind] = [.usb, .bluetooth]
    ) async throws -> [HardwareDeviceInfo] {
        guard !transports.isEmpty else {
            throw WalletKitError.transportUnavailable(reason: "no transports requested")
        }
        // No real transport (USB/Bluetooth) integration yet, so nothing is
        // ever discovered — correct behavior with no device connected.
        return []
    }

    /// Connects to a previously discovered device.
    ///
    /// - Parameters:
    ///   - info: The device to connect to, as returned by ``scan``.
    ///   - delegate: The delegate to relay input/confirmation requests and
    ///     disconnection events to.
    /// - Returns: The connected device.
    /// - Throws: Currently always throws
    ///   ``WalletKitError/deviceNotFound`` — see the type-level note.
    public func connect(_ info: HardwareDeviceInfo, delegate: HardwareDeviceDelegate) async throws -> HardwareDevice {
        throw WalletKitError.deviceNotFound
    }
}
