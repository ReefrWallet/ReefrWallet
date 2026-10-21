//
//  HardwareService.swift
//  ReefrWallet
//
//  Created by Andrey Yurkevich on 22/08/2026.
//

import WalletKit

/// Connects to hardware keys and relays their user-interaction requests to
/// ``promptCenter``.
final class HardwareService {
    let manager = HardwareDeviceManager()

    /// Hardware key prompts for the UI to present.
    let promptCenter = HardwareKeyPromptCenter()

    private static let maxConnectAttempts = 5
    private static let maxReconnectAttempts = 3
    private static let retryDelay = Duration.seconds(1)

    /// Scans for connected hardware keys.
    ///
    /// - Parameters:
    ///   - vendor: The vendor to scan for.
    ///   - transport: The transport to scan over.
    /// - Returns: The devices currently connected.
    func scanDevices(
        _ vendor: HardwareVendor = .trezor,
        transport: HardwareTransportKind = .usb
    ) async throws -> [HardwareDeviceInfo] {
        let devices = try await manager.scan(vendors: [vendor], transports: [transport])
        return devices
    }

    /// Connects to the hardware key with `deviceId`.
    ///
    /// If the key isn't connected, shows a "Connect `keyName`" prompt and
    /// waits until it appears. A just-plugged key fails its handshake while
    /// booting, so a failed connection is retried after a second, up to 5
    /// attempts. Call inside ``session(showsWait:_:)`` so confirmation
    /// prompts raised while the device is in use get dismissed.
    ///
    /// - Parameters:
    ///   - vendor: The key's vendor.
    ///   - deviceId: The key's device identifier, as stored in its key store.
    ///   - keyName: The key store's name, shown in prompts.
    ///   - transport: The transport to connect over.
    /// - Returns: The connected device.
    /// - Throws: `WalletKitError.userCancelled` if the user cancels the
    ///   connect prompt, `CancellationError` if the task is cancelled while
    ///   waiting, or any scan or connection error.
    func connect(
        _ vendor: HardwareVendor,
        deviceId: String,
        keyName: String,
        transport: HardwareTransportKind = .usb
    ) async throws -> HardwareDevice {
        var attempt = 1

        while true {
            // Rescan every attempt: the manager consumes a scan entry on connect.
            let deviceInfo = try await waitForDevice(vendor, deviceId: deviceId, keyName: keyName, transport: transport)
            await promptCenter.didConnect(keyName: keyName, deviceId: deviceId)

            do {
                return try await manager.connect(deviceInfo, delegate: self)
            } catch WalletKitError.deviceDisconnected where attempt < Self.maxConnectAttempts {
                attempt += 1
                try await Task.sleep(for: Self.retryDelay)
            }
        }
    }

    /// Runs a hardware key operation, keeping its prompts up until it finishes.
    ///
    /// Devices don't report when the user has confirmed on them, so a
    /// "Continue on" prompt stays up until the outermost session ends.
    /// `operation` is rerun after a second, up to 3 attempts in all, when it throws
    /// `WalletKitError.deviceDisconnected`, so it should connect through
    /// ``connect(_:deviceId:keyName:transport:)`` itself. Sessions nest.
    ///
    /// - Parameters:
    ///   - showsWait: Whether to show "please wait" once the key is
    ///     connected, for slow work with no confirmation, like exporting
    ///     public keys. A confirm prompt replaces it.
    ///   - operation: Work that connects to and uses a hardware key.
    /// - Returns: The result of `operation`.
    /// - Throws: Whatever `operation` throws, including the last
    ///   `WalletKitError.deviceDisconnected` once attempts run out.
    func session<T>(showsWait: Bool = false, _ operation: () async throws -> T) async throws -> T {
        await promptCenter.beginSession(showsWait: showsWait)

        do {
            let result = try await retryingOnDisconnect(operation)
            await promptCenter.endSession(showsWait: showsWait)
            return result
        } catch {
            await promptCenter.endSession(showsWait: showsWait)
            throw error
        }
    }
}

private extension HardwareService {
    func findDevice(
        _ vendor: HardwareVendor,
        deviceId: String,
        transport: HardwareTransportKind
    ) async throws -> HardwareDeviceInfo? {
        try await scanDevices(vendor, transport: transport).first { $0.id == deviceId }
    }

    func retryingOnDisconnect<T>(_ operation: () async throws -> T) async throws -> T {
        var attempt = 1

        while true {
            do {
                return try await operation()
            } catch WalletKitError.deviceDisconnected where attempt < Self.maxReconnectAttempts {
                attempt += 1
                try await Task.sleep(for: Self.retryDelay)
            }
        }
    }

    func waitForDevice(
        _ vendor: HardwareVendor,
        deviceId: String,
        keyName: String,
        transport: HardwareTransportKind
    ) async throws -> HardwareDeviceInfo {
        if let deviceInfo = try await findDevice(vendor, deviceId: deviceId, transport: transport) {
            return deviceInfo
        }

        await promptCenter.showConnect(keyName: keyName)

        do {
            while true {
                try await Task.sleep(for: .seconds(1))

                guard await !promptCenter.isCancelled else {
                    throw WalletKitError.userCancelled
                }

                if let deviceInfo = try await findDevice(vendor, deviceId: deviceId, transport: transport) {
                    await promptCenter.dismiss()
                    return deviceInfo
                }
            }
        } catch {
            await promptCenter.dismiss()
            throw error
        }
    }
}

extension HardwareService: HardwareDeviceDelegate {
    func hardwareDevice(_ device: HardwareDevice, needsInput request: HardwareInputRequest) async -> String? {
        return nil
    }

    func hardwareDevice(_ device: HardwareDevice, waitingForConfirmation request: HardwareButtonRequest) async {
        await promptCenter.showConfirm(deviceId: device.info.id, fallbackName: device.info.label ?? "Hardware Key")
    }

    func hardwareDeviceDidDisconnect(_ device: WalletKit.HardwareDevice) {
    }
}
