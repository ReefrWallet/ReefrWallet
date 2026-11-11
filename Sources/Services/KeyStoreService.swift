import SwiftData
import WalletKit

final class KeyStoreService {
    private lazy var accountService = DI.injectOrFail(AccountService.self)
    private lazy var databaseService = DI.injectOrFail(DatabaseService.self)
    private lazy var hardwareService = DI.injectOrFail(HardwareService.self)
    private lazy var keyVault = DI.injectOrFail(KeyVault.self)

    @discardableResult @MainActor
    func addLocalKey(_ mnemonic: Mnemonic) async throws -> KeyStore? {
        try await saveLocalKey(secret: mnemonic.entropy, kind: .bip39, wordlist: mnemonic.wordlist)
    }

    /// Saves a key store restored from SLIP-39 shares; only the master
    /// secret is kept, sealed like BIP-39 entropy.
    @discardableResult @MainActor
    func addLocalKey(slip39MasterSecret: Data) async throws -> KeyStore? {
        try await saveLocalKey(secret: slip39MasterSecret, kind: .slip39, wordlist: nil)
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

    func generateSeedPhrase(wordCount: MnemonicWordCount = .`12`) -> String {
        Mnemonic.generate(wordCount: wordCount).phrase
    }

    /// Seals and inserts a local key store. A failed or cancelled insert
    /// discards the vault key and nothing is saved. Once saved the key
    /// store exists, so a failed re-fetch isn't an error: a retry could
    /// otherwise save a duplicate.
    @MainActor
    private func saveLocalKey(secret: Data, kind: KeyStore.SecretKind, wordlist: Wordlist?) async throws -> KeyStore? {
        let sealed = try keyVault.seal(secret)
        let keyStore = KeyStore(
            deviceId: nil,
            kind: .local,
            name: "Local Key",
            mnemonicWordlist: wordlist,
            sealedEntropy: sealed,
            secretKind: kind,
            transport: nil,
            vendor: nil
        )

        let keyStoreId: PersistentIdentifier

        do {
            keyStoreId = try await databaseService.insertKeyStore(keyStore)
        } catch {
            keyVault.discard(sealed)
            throw error
        }

        return try? await databaseService.fetchKeyStore(id: keyStoreId)
    }
}
