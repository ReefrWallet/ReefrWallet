// Spec-driven test for Docs/Design Specification/Core/CoinType.swift.
// Will compile once the corresponding type is exported from Sources.

import Testing
@testable import WalletKit

struct CoinTypeTests {
    @Test(arguments: [
        (CoinType.bitcoin, UInt32(0), Curve.secp256k1, "bitcoin"),
        (CoinType.ethereum, UInt32(60), Curve.secp256k1, "ethereum"),
        (CoinType.tron, UInt32(195), Curve.secp256k1, "tron"),
        (CoinType.solana, UInt32(501), Curve.ed25519, "solana"),
        (CoinType.cardano, UInt32(1815), Curve.ed25519, "cardano"),
        (CoinType.sui, UInt32(784), Curve.ed25519, "sui"),
    ])
    func registryEntryMatchesSLIP44(coinType: CoinType, slip44Index: UInt32, curve: Curve, identifier: String) {
        #expect(coinType.slip44Index == slip44Index)
        #expect(coinType.curve == curve)
        #expect(coinType.identifier == identifier)
    }

    @Test func customCoinTypeRoundTripsThroughInit() {
        let custom = CoinType(slip44Index: 9999, curve: .secp256k1, identifier: "testnet")
        #expect(custom.slip44Index == 9999)
        #expect(custom.curve == .secp256k1)
        #expect(custom.identifier == "testnet")
    }

    @Test func equalityIsValueBased() {
        #expect(CoinType.bitcoin == CoinType(slip44Index: 0, curve: .secp256k1, identifier: "bitcoin"))
    }
}
