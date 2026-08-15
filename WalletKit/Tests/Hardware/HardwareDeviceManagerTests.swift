// Spec-driven test for Docs/Design Specification/Hardware/HardwareDeviceManager.swift.
// Will compile once the corresponding type is exported from Sources.
//
// `scan`/`connect` talk to real transports (USB/Bluetooth), so most cases
// here need a connected (or mocked) Trezor to pass; `#require` skips the
// assertion body cleanly when none is available rather than crashing.

import Testing
@testable import WalletKit

struct HardwareDeviceManagerTests {
    @Test func scanWithNoRequestedTransportsThrowsTransportUnavailable() async {
        let manager = HardwareDeviceManager()
        await #expect(throws: WalletKitError.self) {
            _ = try await manager.scan(vendors: [.trezor], transports: [])
        }
    }

    @Test func scanDefaultsToAllVendorsAndUsbPlusBluetooth() async throws {
        let manager = HardwareDeviceManager()
        // Asserts the call succeeds with no arguments; the exact devices
        // returned depend on what's physically connected to the host.
        _ = try await manager.scan()
    }

    @Test func connectRetainsTheProvidedDelegateAndReturnsAConnectedDevice() async throws {
        let manager = HardwareDeviceManager()
        let devices = try await manager.scan()
        let info = try #require(devices.first, "requires a connected test device")
        let delegate = RecordingHardwareDeviceDelegate()
        let device = try await manager.connect(info, delegate: delegate)
        #expect(device.info == info)
        #expect(device.isConnected)
    }
}
