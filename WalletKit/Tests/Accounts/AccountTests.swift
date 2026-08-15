// Spec-driven test for Docs/Design Specification/Accounts/Account.swift.
// Will compile once the corresponding type is exported from Sources.
//
// `Account` is produced by a `KeyProvider` (`Wallet` here); it has no public
// initializer of its own, so these tests exercise it through `Wallet`.

import Testing
@testable import WalletKit

struct AccountTests {
    @Test func accountCarriesTheRequestedBlockchainAndDefaultsToIndexZero() async throws {
        let wallet = Wallet.create()
        let account = try await wallet.account(.ethereum)
        #expect(account.blockchain == .ethereum)
        #expect(account.curve == .secp256k1)
        #expect(account.source == .software)
    }

    @Test func derivationPathMatchesTheRequestedAccountIndex() async throws {
        let wallet = Wallet.create()
        let account = try await wallet.account(.ethereum, account: 3)
        #expect(account.derivationPath == Blockchain.ethereum.derivationPath(account: 3))
    }

    @Test func publicKeyMatchesManualDerivationAtTheSamePath() async throws {
        let wallet = Wallet.create()
        let account = try await wallet.account(.bitcoin)
        let manualKey = try await wallet.publicKey(path: account.derivationPath, curve: .secp256k1)
        #expect(account.publicKey.rawBytes == manualKey.rawBytes)
    }
}
