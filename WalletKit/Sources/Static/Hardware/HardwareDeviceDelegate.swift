//
//  HardwareDeviceDelegate.swift
//  WalletKit
//
//  Created by Andrey Yurkevich on 20/08/2026.
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

/// Callbacks a ``HardwareDevice`` uses to relay user-interaction requests
/// and lifecycle events back to the app.
public protocol HardwareDeviceDelegate: AnyObject {
    /// Called when `device` needs the user to provide a piece of input
    /// (a PIN or passphrase).
    ///
    /// - Parameters:
    ///   - device: The device requesting input.
    ///   - request: What kind of input is being requested.
    /// - Returns: The user-provided value, or `nil` if the user cancelled.
    func hardwareDevice(_ device: HardwareDevice, needsInput request: HardwareInputRequest) async -> String?

    /// Called when `device` is waiting for the user to physically confirm
    /// something on the device itself.
    ///
    /// - Parameters:
    ///   - device: The device waiting for confirmation.
    ///   - request: What's being confirmed.
    func hardwareDevice(_ device: HardwareDevice, waitingForConfirmation request: HardwareButtonRequest) async

    /// Called when `device` disconnects, whether initiated by the app
    /// (``HardwareDevice/disconnect()``) or externally (e.g. the user
    /// unplugged it).
    ///
    /// - Parameter device: The device that disconnected.
    func hardwareDeviceDidDisconnect(_ device: HardwareDevice)
}
