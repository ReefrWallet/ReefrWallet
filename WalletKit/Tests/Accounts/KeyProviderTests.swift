// Spec-driven test for Docs/Design Specification/Accounts/KeyProvider.swift.
//
// No software `KeyProvider` conformer exists in the public API anymore
// (see Account's design-spec doc comment) — `HardwareDevice` is the real
// conformer, covered in Tests/Hardware/HardwareDeviceTests.swift, since it
// requires a connected (or mocked) physical device. This exercises the
// protocol's shape itself through a local mock, independent of any one
// source.

import Testing
@testable import WalletKit

private final class MockKeyProvider: KeyProvider {
    let source: KeySource
    let publicKeyHandler: (DerivationPath, Curve) async throws -> PublicKey
    let accountHandler: (Blockchain, UInt32) async throws -> Account

    init(
        source: KeySource,
        publicKeyHandler: @escaping (DerivationPath, Curve) async throws -> PublicKey,
        accountHandler: @escaping (Blockchain, UInt32) async throws -> Account
    ) {
        self.source = source
        self.publicKeyHandler = publicKeyHandler
        self.accountHandler = accountHandler
    }

    func publicKey(path: DerivationPath, curve: Curve) async throws -> PublicKey {
        try await publicKeyHandler(path, curve)
    }

    func account(_ blockchain: Blockchain, account: UInt32) async throws -> Account {
        try await accountHandler(blockchain, account)
    }
}

struct KeyProviderTests {
    @Test func sourceReflectsTheConformersOrigin() {
        let provider = MockKeyProvider(
            source: .software,
            publicKeyHandler: { _, _ in throw WalletKitError.keyNotFound },
            accountHandler: { _, _ in throw WalletKitError.keyNotFound }
        )
        #expect(provider.source == .software)
    }

    @Test func publicKeyAndAccountAgreeOnTheSameUnderlyingKey() async throws {
        let account = try TestAccountFactory.ethereumAccount()
        let provider = MockKeyProvider(
            source: .software,
            publicKeyHandler: { _, _ in account.publicKey },
            accountHandler: { _, _ in account }
        )

        let key = try await provider.publicKey(path: account.derivationPath, curve: account.curve)
        let viaAccount = try await provider.account(account.blockchain, account: 0)
        #expect(key.rawBytes == viaAccount.publicKey.rawBytes)
    }
}
