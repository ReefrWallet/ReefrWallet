import WalletKit

final class KeyStoreService {
    private lazy var databaseService = DI.injectOrFail(DatabaseService.self)
    private lazy var deviceManager = HardwareDeviceManager()

    @discardableResult @MainActor
    func addLocalKey(_ mnemonic: Mnemonic) async throws -> KeyStore? {
        let keyStore = KeyStore(
            deviceId: nil,
            kind: .local,
            name: "Local Key",
            mnemonicEntropy: mnemonic.entropy,
            mnemonicWordlist: mnemonic.wordlist,
            transport: nil,
            vendor: nil
        )

        let keyStoreId = try await databaseService.insertKeyStore(keyStore)
        return try await databaseService.fetchKeyStore(id: keyStoreId)
    }

    @MainActor
    func connectTrezor() async throws {
        let devices = try await deviceManager.scan(vendors: [.trezor], transports: [.usb])
        printInfo("Found \(devices.count) devices")

        guard let device = devices.first else {
            throw ReefrError.notFound
        }

        let keyStore = KeyStore(
            deviceId: device.id,
            kind: .trezor,
            name: device.label ?? "Trezor",
            transport: .usb,
            vendor: device.vendor
        )

        try await databaseService.insertKeyStore(keyStore)
    }

    func generateSeedPhrase() -> String {
        Mnemonic.generate().phrase
    }
}
