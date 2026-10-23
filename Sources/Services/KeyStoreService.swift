import WalletKit

final class KeyStoreService {
    private lazy var accountService = DI.injectOrFail(AccountService.self)
    private lazy var databaseService = DI.injectOrFail(DatabaseService.self)
    private lazy var hardwareService = DI.injectOrFail(HardwareService.self)

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
        let addedIds = try await Set(databaseService.hardwareDeviceIds())

        let device = try await hardwareService.session {
            let device = try await hardwareService.connect(.trezor, where: { !addedIds.contains($0.id) })
            await device?.disconnect()
            return device
        }

        guard let device else {
            throw ReefrError.alreadyExists
        }

        let info = device.info
        let keyStore = KeyStore(
            deviceId: info.id,
            kind: .trezor,
            name: info.label ?? "\(info.vendor.displayName) \(info.model)",
            model: info.model,
            transport: info.transport,
            vendor: info.vendor
        )

        try await databaseService.insertKeyStore(keyStore)
    }

    /// Deletes `keyStore` with its accounts and disconnects dapps from them.
    ///
    /// - Throws: ``ReefrError/notFound`` if `keyStore` was never stored, or a database error.
    func deleteKeyStore(_ keyStore: KeyStore) async throws {
        guard let keyStoreId = keyStore.id else {
            throw ReefrError.notFound
        }

        let accounts = try await databaseService.fetchAccounts(keyStoreId: keyStoreId)
        try await databaseService.deleteKeyStore(id: keyStoreId)
        await accountService.disconnectDapps(from: accounts)
    }

    func generateSeedPhrase() -> String {
        Mnemonic.generate().phrase
    }
}
