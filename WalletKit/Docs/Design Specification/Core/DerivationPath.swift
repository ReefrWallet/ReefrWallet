//
//  DerivationPath.swift
//  WalletKit
//
//  DESIGN SPEC — not generated code. See Walletkit/Docs/Overview.md for
//  module-level notes and architecture.
//

/// A parsed BIP32/SLIP-10 style path, e.g. "m/44'/60'/0'/0/0".
public struct DerivationPath: Equatable {
    public struct Segment: Equatable {
        public let index: UInt32
        public let hardened: Bool

        public init(index: UInt32, hardened: Bool) {
            self.index = index
            self.hardened = hardened
        }
    }

    public let segments: [Segment]

    public init(segments: [Segment]) {
        self.segments = segments
    }

    /// Parses strings like "m/44'/60'/0'/0/0". Throws `.invalidDerivationPath`
    /// on malformed input.
    public init(string: String) throws {
        fatalError("spec only")
    }

    public var string: String { fatalError("spec only") }

    /// Convenience constructor for the common
    /// `m/purpose'/coin_type'/account'/change/index` shape.
    public static func bip44(
        purpose: UInt32 = 44,
        coinType: CoinType,
        account: UInt32 = 0,
        change: UInt32 = 0,
        index: UInt32 = 0
    ) -> DerivationPath {
        fatalError("spec only")
    }
}
