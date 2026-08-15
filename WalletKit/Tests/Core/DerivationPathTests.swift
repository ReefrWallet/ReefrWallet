// Spec-driven test for Docs/Design Specification/Core/DerivationPath.swift.
// Will compile once the corresponding type is exported from Sources.

import Testing
@testable import WalletKit

struct DerivationPathTests {
    @Test func parsesStandardBip44String() throws {
        let path = try DerivationPath(string: "m/44'/60'/0'/0/0")
        #expect(path.segments.map(\.index) == [44, 60, 0, 0, 0])
        #expect(path.segments.map(\.hardened) == [true, true, true, false, false])
    }

    @Test func stringRoundTripsThroughParsing() throws {
        let original = "m/44'/60'/0'/0/0"
        let path = try DerivationPath(string: original)
        #expect(path.string == original)
    }

    @Test func invalidStringThrowsInvalidDerivationPath() {
        #expect(throws: WalletKitError.self) {
            _ = try DerivationPath(string: "not-a-path")
        }
    }

    @Test func bip44ConvenienceMatchesManualSegments() {
        let convenience = DerivationPath.bip44(coinType: .ethereum, account: 0, change: 0, index: 0)
        let manual = DerivationPath(segments: [
            .init(index: 44, hardened: true),
            .init(index: 60, hardened: true),
            .init(index: 0, hardened: true),
            .init(index: 0, hardened: false),
            .init(index: 0, hardened: false),
        ])
        #expect(convenience == manual)
    }
}
