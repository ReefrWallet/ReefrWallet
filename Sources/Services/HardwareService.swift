//
//  HardwareService.swift
//  ReefrWallet
//
//  Created by Andrey Yurkevich on 22/08/2026.
//

import WalletKit

final class HardwareService {
    let manager = HardwareDeviceManager()

    /// Scans for and returns list of connected devices
    func scanDevices(
        _ vendor: HardwareVendor = .trezor,
        transport: HardwareTransportKind = .usb
    ) async throws -> [HardwareDeviceInfo] {
        let devices = try await manager.scan(vendors: [vendor], transports: [transport])
        return devices
    }

    func connect(
        _ vendor: HardwareVendor,
        deviceId: String,
        transport: HardwareTransportKind = .usb
    ) async throws -> HardwareDevice {
        guard let deviceInfo = try await scanDevices().first(where: { deviceId == $0.id }) else {
            throw Error.notFound
        }

        let device = try await manager.connect(deviceInfo, delegate: self)
        return device
    }
}

extension HardwareService: HardwareDeviceDelegate {
    func hardwareDevice(_ device: HardwareDevice, needsInput request: HardwareInputRequest) async -> String? {
        return nil
    }

    func hardwareDevice(_ device: HardwareDevice, waitingForConfirmation request: HardwareButtonRequest) async {
    }

    func hardwareDeviceDidDisconnect(_ device: WalletKit.HardwareDevice) {
    }
}
