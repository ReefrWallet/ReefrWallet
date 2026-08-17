// Spec-driven test for Docs/Design Specification/Core/Blockchain.swift.
//
// `Blockchain` is a plain chain identifier — it carries no curve or
// derivation-path logic of its own (see Account/TestAccountFactory for
// that). Some cases carry the extra configuration a `Signer` needs beyond
// the identifier itself: `.ethereum`'s chain ID, `.sui`'s signature scheme.

import Testing
@testable import WalletKit
import WalletKitRust

struct BlockchainTests {
    @Test func argumentLessCasesAreEqualToThemselves() {
        #expect(Blockchain.bitcoin == Blockchain.bitcoin)
        #expect(Blockchain.tron == Blockchain.tron)
        #expect(Blockchain.solana == Blockchain.solana)
        #expect(Blockchain.cardano == Blockchain.cardano)
    }

    @Test func distinctArgumentLessCasesAreNotEqual() {
        #expect(Blockchain.bitcoin != Blockchain.tron)
        #expect(Blockchain.solana != Blockchain.cardano)
    }

    @Test func ethereumCasesCompareByChainID() {
        #expect(Blockchain.ethereum(1) == Blockchain.ethereum(1))
        #expect(Blockchain.ethereum(1) != Blockchain.ethereum(11_155_111))
    }

    @Test func suiCasesCompareByCurve() {
        #expect(Blockchain.sui(.ed25519) == Blockchain.sui(.ed25519))
        #expect(Blockchain.sui(.ed25519) != Blockchain.sui(.secp256k1))
    }

    @Test func ethereumAndSuiAreNeverEqualToUnrelatedCases() {
        #expect(Blockchain.ethereum(1) != Blockchain.bitcoin)
        #expect(Blockchain.sui(.ed25519) != Blockchain.solana)
    }
}
