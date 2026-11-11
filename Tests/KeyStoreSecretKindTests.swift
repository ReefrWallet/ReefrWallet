// Local key stores hold either BIP-39 entropy or a SLIP-39 master secret;
// accounts derive from either, and stores saved before SLIP-39 keep working.

import Foundation
import Testing
import WalletKit
@testable import ReefrWallet

@MainActor
struct KeyStoreSecretKindTests {
    private func keyStore(secret: Data, kind: KeyStore.SecretKind?) -> KeyStore {
        if let kind {
            return KeyStore(
                deviceId: nil,
                kind: .local,
                name: "Local",
                sealedEntropy: secret,
                secretKind: kind,
                transport: nil,
                vendor: nil
            )
        }

        // A store as saved before SLIP-39: no secret kind at all.
        return KeyStore(deviceId: nil, kind: .local, name: "Local", sealedEntropy: secret, transport: nil, vendor: nil)
    }

    /// The account key at an Ethereum path, as hex.
    private func ethereumAddress(_ seed: Seed) throws -> String {
        let path = try DerivationPath(string: "m/44'/60'/0'/0/0")
        return try seed.masterKey(curve: .secp256k1).derive(path).privateKey().publicKey.rawBytes
            .map { String(format: "%02x", $0) }.joined()
    }

    @Test(arguments: [16, 32])
    func aSlip39KeyStoreDerivesFromItsMasterSecret(length: Int) async throws {
        let secret = Data((0 ..< length).map { UInt8($0 + 1) })
        let store = keyStore(secret: secret, kind: .slip39)

        let seed = try await store.localSeed()

        #expect(seed.exportRaw() == secret)
        #expect(try ethereumAddress(seed) == ethereumAddress(Seed(masterSecret: secret)))
        await #expect(throws: ReefrError.self) { _ = try await store.localMnemonic() }
    }

    @Test
    func aStoreSavedBeforeSlip39ReadsAsBip39AndDerivesTheSameAddress() async throws {
        let entropy = Data(repeating: 9, count: 16)
        let old = keyStore(secret: entropy, kind: nil)

        let seed = try await old.localSeed()

        #expect(old.secretKind == .bip39)
        #expect(seed.exportRaw().count == 64)
        #expect(try ethereumAddress(seed) == ethereumAddress(Mnemonic.fromEntropy(entropy).toSeed()))
        #expect(try await old.localMnemonic().entropy == entropy)
    }

    @Test
    func cardanoRootFollowsTheSecretKind() async throws {
        let secret = Data(repeating: 4, count: 16)

        guard case .slip39MasterSecret = try await keyStore(secret: secret, kind: .slip39).localCardanoRoot() else {
            Issue.record("expected a SLIP-39 root")
            return
        }

        guard case .bip39Entropy = try await keyStore(secret: secret, kind: nil).localCardanoRoot() else {
            Issue.record("expected an Icarus root")
            return
        }
    }

    @Test
    func anUnrecognizedSecretKindIsRejectedNotTreatedAsBip39() throws {
        let model = KeyStoreModel(.local, name: "Local", mnemonicEntropy: Data(repeating: 1, count: 16))
        model.rawSecretKind = "slip99"

        #expect(throws: ReefrError.self) { _ = try KeyStore(model: model) }

        model.rawSecretKind = nil
        #expect(try KeyStore(model: model).secretKind == .bip39)
    }
}
