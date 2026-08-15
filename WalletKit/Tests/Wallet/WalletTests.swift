// Spec-driven test for Docs/Design Specification/Wallet/Wallet.swift.
// Will compile once the corresponding type is exported from Sources.

import Foundation
import Testing
@testable import WalletKit

struct WalletTests {
    @Test func createDefaultsToA24WordMnemonicAndSoftwareSource() {
        let wallet = Wallet.create()
        #expect(wallet.mnemonic.wordCount == .words24)
        #expect(wallet.source == .software)
    }

    @Test func restoreRoundTripsACreatedWalletsPhrase() throws {
        let original = Wallet.create(wordCount: .words12)
        let restored = try Wallet.restore(phrase: original.mnemonic.phrase)
        #expect(restored.mnemonic.phrase == original.mnemonic.phrase)
    }

    @Test func restoreThrowsOnAnInvalidPhrase() {
        #expect(throws: WalletKitError.self) {
            _ = try Wallet.restore(phrase: "definitely not a bip39 phrase")
        }
    }

    @Test func restoreEncryptedThrowsOnAWrongPassword() throws {
        let wallet = Wallet.create()
        let encrypted = try wallet.exportEncryptedBackup(password: "correct-password")
        #expect(throws: WalletKitError.self) {
            _ = try Wallet.restoreEncrypted(data: encrypted, password: "wrong-password")
        }
    }

    @Test func restoreEncryptedRoundTripsWithTheCorrectPassword() throws {
        let wallet = Wallet.create()
        let encrypted = try wallet.exportEncryptedBackup(password: "correct-password")
        let restored = try Wallet.restoreEncrypted(data: encrypted, password: "correct-password")
        #expect(restored.mnemonic.phrase == wallet.mnemonic.phrase)
    }

    @Test func deriveAndAccountAgreeOnTheSameStandardPath() async throws {
        let wallet = Wallet.create()
        let path = Blockchain.ethereum.derivationPath()
        let extendedKey = try wallet.derive(path, curve: .secp256k1)
        let account = try await wallet.account(.ethereum)
        #expect(extendedKey.publicKey.rawBytes == account.publicKey.rawBytes)
    }

    @Test func exportBackupCarriesTheWalletsMnemonicAndWordlist() {
        let wallet = Wallet.create(wordCount: .words12)
        let backup = wallet.exportBackup()
        #expect(backup.phrase == wallet.mnemonic.phrase)
        #expect(backup.wordlist == wallet.mnemonic.wordlist)
    }
}
