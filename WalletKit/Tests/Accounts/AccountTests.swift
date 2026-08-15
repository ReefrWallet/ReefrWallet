// Spec-driven test for Docs/Design Specification/Core/Account.swift.
//
// `Account` has no public initializer of its own — no software
// `KeyProvider` conformer exists in the public API anymore (see Account's
// design-spec doc comment), so these tests build one via
// `TestAccountFactory`, which uses `Account`'s internal initializer
// directly (visible here via `@testable import`).

import Testing
@testable import WalletKit

struct AccountTests {
    @Test func accountCarriesTheRequestedBlockchainCurveAndSource() throws {
        let account = try TestAccountFactory.ethereumAccount()
        #expect(account.blockchain == .ethereum(1))
        #expect(account.curve == .secp256k1)
        #expect(account.source == .software)
    }

    @Test func derivationPathMatchesTheRequestedAccountIndex() throws {
        let account = try TestAccountFactory.ethereumAccount(account: 3)
        #expect(account.derivationPath == TestAccountFactory.bip44Path(coinType: 60, account: 3))
    }
}
