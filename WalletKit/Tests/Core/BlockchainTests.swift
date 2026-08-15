// Spec-driven test for Docs/Design Specification/Core/Blockchain.swift.
// Will compile once the corresponding type is exported from Sources.

import Testing
@testable import WalletKit

struct BlockchainTests {
    @Test(arguments: [Blockchain.bitcoin, .ethereum, .tron, .solana, .cardano, .sui])
    func defaultPurposeIs44(blockchain: Blockchain) {
        #expect(blockchain.purpose == 44)
    }

    @Test func curveIsForwardedFromCoinType() {
        #expect(Blockchain.ethereum.curve == .secp256k1)
        #expect(Blockchain.solana.curve == .ed25519)
    }

    @Test func identifierIsForwardedFromCoinType() {
        #expect(Blockchain.bitcoin.identifier == "bitcoin")
    }

    @Test func derivationPathUsesBip44Shape() {
        let path = Blockchain.ethereum.derivationPath(account: 0, change: 0, index: 0)
        #expect(path == .bip44(purpose: 44, coinType: .ethereum, account: 0, change: 0, index: 0))
    }

    @Test func customPurposeOverridesDefault() {
        // Purpose 49 = BIP49 nested SegWit; exercises the non-default path.
        let blockchain = Blockchain(coinType: .bitcoin, purpose: 49)
        #expect(blockchain.purpose == 49)
    }
}
