//
//  HardwareDevice.swift
//  WalletKit
//
//  Created by Andrey Yurkevich on 20/08/2026.
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

/// A connected hardware wallet.
///
/// Obtained from ``HardwareDeviceManager/connect(_:delegate:)``.
public final class HardwareDevice: HardwareDeviceProtocol {
    /// Static metadata describing this device.
    public let info: HardwareDeviceInfo

    /// Whether this device is still connected.
    public private(set) var isConnected: Bool

    private weak var delegate: HardwareDeviceDelegate?

    public init(info: HardwareDeviceInfo, delegate: HardwareDeviceDelegate?) {
        self.info = info
        self.delegate = delegate
        self.isConnected = true
    }

    /// Where this device's key material lives — always
    /// ``KeySource/hardware(_:)`` with this device's ``info``.
    public var source: KeySource { .hardware(info) }

    /// Reads the public key at `path` for `curve` from the device.
    ///
    /// - Parameters:
    ///   - path: The derivation path to read the public key at.
    ///   - curve: The elliptic curve to derive under.
    /// - Returns: The public key at `path`.
    public func publicKey(path: DerivationPath, curve: Curve) async throws -> PublicKey {
        throw WalletKitError.deviceDisconnected
    }

    /// Builds the ``Account`` for `blockchain` at index `account` from the
    /// device.
    ///
    /// - Parameters:
    ///   - blockchain: The blockchain to build the account for.
    ///   - account: The BIP44-style account index.
    /// - Returns: The resulting account, including its derived public key.
    public func account(_ blockchain: Blockchain, account: UInt32 = 0) async throws -> Account {
        throw WalletKitError.deviceDisconnected
    }

    /// Disconnects from this device and notifies the delegate.
    public func disconnect() async {
        isConnected = false
        delegate?.hardwareDeviceDidDisconnect(self)
    }
}
