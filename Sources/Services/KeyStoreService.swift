import Foundation
import WalletKit

final class KeyStoreService {
    private lazy var databaseService = DI.injectOrFail(DatabaseService.self)
    private lazy var deviceManager = HardwareDeviceManager()

    @MainActor
    func addLocalKey(_ mnemonic: Mnemonic) async throws {
        let keyStore = KeyStore(
            deviceId: nil,
            kind: .local,
            name: "Local Key",
            rawKey: mnemonic.toSeed().exportRaw(),
            transport: nil,
            vendor: nil
        )

        try await databaseService.insertKeyStore(keyStore)
    }

    @MainActor
    func connectTrezor() async throws {
        let devices = try await deviceManager.scan(vendors: [.trezor], transports: [.usb])
        printInfo("Found \(devices.count) devices")

        guard let device = devices.first else {
            throw Error.notFound
        }

        let keyStore = KeyStore(
            deviceId: device.id,
            kind: .trezor,
            name: device.label ?? "Trezor",
            rawKey: nil,
            transport: .usb,
            vendor: device.vendor
        )

        try await databaseService.insertKeyStore(keyStore)
    }

    func generateSeedPhrase() -> String {
        Mnemonic.generate(wordCount: .words12).phrase
    }
}
