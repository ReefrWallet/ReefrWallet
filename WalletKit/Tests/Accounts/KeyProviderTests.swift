// Spec-driven test for Docs/Design Specification/Accounts/KeyProvider.swift.
// Will compile once the corresponding type is exported from Sources.
//
// `Wallet` is the software-backed conformer exercised here. The
// hardware-backed conformer, `HardwareDevice`, is covered in
// Tests/Hardware/HardwareDeviceTests.swift, since it requires a connected
// (or mocked) physical device.

import Testing
@testable import WalletKit

struct KeyProviderTests {
    @Test func walletConformsToKeyProviderWithASoftwareSource() {
        let wallet: any KeyProvider = Wallet.create()
        #expect(wallet.source == .software)
    }

    @Test func publicKeyAndAccountAgreeOnTheSameProviderAndPath() async throws {
        let wallet: any KeyProvider = Wallet.create()
        let account = try await wallet.account(.solana, account: 0)
        let key = try await wallet.publicKey(path: account.derivationPath, curve: .ed25519)
        #expect(account.publicKey.rawBytes == key.rawBytes)
    }
}
