//
//  HardwareService.swift
//  ReefrWallet
//
//  Created by Andrey Yurkevich on 22/08/2026.
//

import Foundation
import WalletKit

// MARK: - HardwareServiceError

enum HardwareServiceError: LocalizedError {
    case wrongDevice(vendor: HardwareVendor)

    var errorDescription: String? {
        switch self {
        case let .wrongDevice(vendor):
            String(localized: .hardwareWrongDevice(vendor.displayName))
        }
    }
}

// MARK: - HardwareService

/// Connects to hardware keys and relays their user-interaction requests to
/// ``promptCenter``.
final class HardwareService {
    let manager = HardwareDeviceManager()

    /// Hardware key prompts for the UI to present.
    let promptCenter = HardwareKeyPromptCenter()

    /// Devices connected so far, kept alive between sessions. WalletKit's manager hands back
    /// the already-open device on a repeat connect and keeps the delegate it was first
    /// connected with, whose weak reference to its ``HardwareDevice`` is nil once that is
    /// released — and the confirm prompts then never reach ``promptCenter``.
    private var connectedDevices: [String: HardwareDevice] = [:]
    private let connectedDevicesLock = NSLock()

    private static let maxConnectAttempts = 5
    private static let maxReconnectAttempts = 3
    private static let retryDelay = Duration.seconds(1)

    init() {
        guard Logger.isVerbose else {
            return
        }

        HardwareLogging.setHandler { Logger.verbose("Hardware: \($0)") }
    }

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
    /// Scans only report a placeholder id, so connected keys are tried in
    /// turn until one reports the real `deviceId`.
    /// If no key is connected, shows a "Connect" prompt and
    /// waits until one appears. A just-plugged key fails its handshake while
    /// booting, so a failed connection is retried after a second, up to 5
    /// attempts. Call inside ``session(showsWait:_:)`` so confirmation
    /// prompts raised while the device is in use get dismissed.
    ///
    /// - Parameters:
    ///   - vendor: The key's vendor.
    ///   - deviceId: The key's device identifier, as stored in its key store.
    ///   - transport: The transport to connect over.
    /// - Returns: The connected device.
    /// - Throws: ``HardwareServiceError/wrongDevice(vendor:)`` if none of
    ///   the connected keys has `deviceId`,
    ///   `WalletKitError.userCancelled` if the user cancels the
    ///   connect prompt, `CancellationError` if the task is cancelled while
    ///   waiting, or any scan or connection error.
    func connect(
        _ vendor: HardwareVendor,
        deviceId: String,
        transport: HardwareTransportKind = .usb
    ) async throws -> HardwareDevice {
        guard let device = try await connect(vendor, transport: transport, where: { $0.id == deviceId }) else {
            throw HardwareServiceError.wrongDevice(vendor: vendor)
        }

        return device
    }

    /// Connects to the first connected key whose info satisfies `isWanted`,
    /// waiting for a key to appear like ``connect(_:deviceId:transport:)``.
    ///
    /// - Parameters:
    ///   - vendor: The key's vendor.
    ///   - transport: The transport to connect over.
    ///   - isWanted: Whether a connected key's real info is the one wanted.
    /// - Returns: The connected device, or `nil` if no connected key is wanted.
    func connect(
        _ vendor: HardwareVendor,
        transport: HardwareTransportKind = .usb,
        where isWanted: (HardwareDeviceInfo) -> Bool
    ) async throws -> HardwareDevice? {
        if let device = cachedDevice(vendor, transport: transport, where: isWanted) {
            return device
        }

        var index = 0

        while true {
            guard let device = try await connectDevice(vendor, transport: transport, at: index) else {
                return nil
            }

            if isWanted(device.info) {
                cache(device)
                return device
            }

            forget(device)
            await device.disconnect()
            await waitUntilDisconnected(device)
            index += 1
        }
    }

    /// Runs a hardware key operation, keeping its prompts up until it finishes.
    ///
    /// Devices don't report when the user has confirmed on them, so a
    /// "Continue on" prompt stays up until the outermost session ends.
    /// `operation` is rerun after a second, up to 3 attempts in all, when it throws
    /// `WalletKitError.deviceDisconnected`, so it should connect through
    /// ``connect(_:deviceId:transport:)`` itself. Sessions nest.
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
    func cache(_ device: HardwareDevice) {
        connectedDevicesLock.lock()
        defer {
            connectedDevicesLock.unlock()
        }

        connectedDevices[device.info.id] = device
    }

    /// A still-connected device from an earlier session that satisfies `isWanted`.
    func cachedDevice(
        _ vendor: HardwareVendor,
        transport: HardwareTransportKind,
        where isWanted: (HardwareDeviceInfo) -> Bool
    ) -> HardwareDevice? {
        connectedDevicesLock.lock()
        defer {
            connectedDevicesLock.unlock()
        }

        connectedDevices = connectedDevices.filter { $0.value.isConnected }

        return connectedDevices.values.first { device in
            device.info.vendor == vendor && device.info.transport == transport && isWanted(device.info)
        }
    }

    func forget(_ device: HardwareDevice) {
        connectedDevicesLock.lock()
        defer {
            connectedDevicesLock.unlock()
        }

        connectedDevices[device.info.id] = nil
    }

    func connectDevice(
        _ vendor: HardwareVendor,
        transport: HardwareTransportKind,
        at index: Int
    ) async throws -> HardwareDevice? {
        var attempt = 1

        while true {
            // Rescan every attempt: the manager consumes a scan entry on connect.
            let deviceInfos = try await waitForDevices(vendor, transport: transport)

            guard index < deviceInfos.count else {
                return nil
            }

            await promptCenter.didConnect(vendorName: vendor.displayName)

            do {
                return try await manager.connect(deviceInfos[index], delegate: self)
            } catch WalletKitError.deviceDisconnected where attempt < Self.maxConnectAttempts {
                attempt += 1
                try await Task.sleep(for: Self.retryDelay)
            }
        }
    }

    func findDevices(
        _ vendor: HardwareVendor,
        transport: HardwareTransportKind
    ) async throws -> [HardwareDeviceInfo]? {
        let devices = try await scanDevices(vendor, transport: transport)
        return devices.isEmpty ? nil : devices
    }

    /// The manager drops a disconnected device from its cache only once its
    /// worker thread has stopped.
    func waitUntilDisconnected(_ device: HardwareDevice) async {
        for _ in 0 ..< 20 where device.isConnected {
            try? await Task.sleep(for: .milliseconds(50))
        }
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

    func waitForDevices(
        _ vendor: HardwareVendor,
        transport: HardwareTransportKind
    ) async throws -> [HardwareDeviceInfo] {
        if let deviceInfos = try await findDevices(vendor, transport: transport) {
            return deviceInfos
        }

        await promptCenter.showConnect(vendorName: vendor.displayName)

        do {
            while true {
                try await Task.sleep(for: .seconds(1))

                guard await !promptCenter.isCancelled else {
                    throw WalletKitError.userCancelled
                }

                if let deviceInfos = try await findDevices(vendor, transport: transport) {
                    await promptCenter.dismiss()
                    return deviceInfos
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
        await promptCenter.showConfirm(vendorName: device.info.vendor.displayName)
    }

    func hardwareDeviceDidDisconnect(_ device: WalletKit.HardwareDevice) {
    }
}

extension HardwareVendor {
    var displayName: String {
        switch self {
        case .trezor: "Trezor"
        }
    }
}
