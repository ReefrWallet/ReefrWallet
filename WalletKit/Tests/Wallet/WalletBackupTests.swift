// Spec-driven test for Docs/Design Specification/Wallet/WalletBackup.swift.
// Will compile once the corresponding type is exported from Sources.

import Testing
@testable import WalletKit

struct WalletBackupTests {
    @Test func initPreservesAllFields() {
        let backup = WalletBackup(phrase: "abandon abandon abandon", wordlist: .english, hasPassphrase: true, createdAt: 1_700_000_000)
        #expect(backup.phrase == "abandon abandon abandon")
        #expect(backup.wordlist == .english)
        #expect(backup.hasPassphrase == true)
        #expect(backup.createdAt == 1_700_000_000)
    }

    @Test func equalityIsValueBased() {
        let a = WalletBackup(phrase: "x", wordlist: .english, hasPassphrase: false, createdAt: 1)
        let b = WalletBackup(phrase: "x", wordlist: .english, hasPassphrase: false, createdAt: 1)
        #expect(a == b)
    }
}
