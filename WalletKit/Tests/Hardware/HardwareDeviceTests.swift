// Spec-driven test for Docs/Design Specification/Hardware/HardwareDevice.swift.
// Will compile once the corresponding type is exported from Sources.
//
// Requires a connected (or mocked) Trezor; `#require` skips cleanly when
// none is available rather than crashing.

import Testing
@testable import WalletKit

struct HardwareDeviceTests {
    @Test func sourceReflectsTheDevicesInfo() async throws {
        let manager = HardwareDeviceManager()
        let devices = try await manager.scan()
        let info = try #require(devices.first, "requires a connected test device")
        let device = try await manager.connect(info, delegate: RecordingHardwareDeviceDelegate())
        #expect(device.source == .hardware(info))
    }

    @Test func accountAndPublicKeyAgreeOnTheSameProviderAndPath() async throws {
        let manager = HardwareDeviceManager()
        let devices = try await manager.scan()
        let info = try #require(devices.first, "requires a connected test device")
        let device = try await manager.connect(info, delegate: RecordingHardwareDeviceDelegate())
        let account = try await device.account(.bitcoin)
        let key = try await device.publicKey(path: account.derivationPath, curve: .secp256k1)
        #expect(account.publicKey.rawBytes == key.rawBytes)
    }

    @Test func disconnectMarksTheDeviceAsNoLongerConnected() async throws {
        let manager = HardwareDeviceManager()
        let devices = try await manager.scan()
        let info = try #require(devices.first, "requires a connected test device")
        let device = try await manager.connect(info, delegate: RecordingHardwareDeviceDelegate())
        await device.disconnect()
        #expect(device.isConnected == false)
    }
}
