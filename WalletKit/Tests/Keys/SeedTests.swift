// Spec-driven test for Docs/Design Specification/Keys/Seed.swift.
// Will compile once the corresponding type is exported from Sources.

import Testing
@testable import WalletKit

struct SeedTests {
    @Test func exportRawProduces64Bytes() {
        let seed = Mnemonic.generate().toSeed()
        #expect(seed.exportRaw().count == 64)
    }

    @Test func masterKeySupportsSecp256k1() throws {
        let seed = Mnemonic.generate().toSeed()
        let key = try seed.masterKey(curve: .secp256k1)
        #expect(key.curve == .secp256k1)
        #expect(key.depth == 0)
    }

    @Test func masterKeySupportsEd25519() throws {
        let seed = Mnemonic.generate().toSeed()
        let key = try seed.masterKey(curve: .ed25519)
        #expect(key.curve == .ed25519)
        #expect(key.depth == 0)
    }
}
