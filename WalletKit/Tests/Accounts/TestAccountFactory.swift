// Shared test helper for constructing `Account`s directly.
//
// There is no software `KeyProvider` conformer in the public API anymore
// (see Docs/Design Specification/Core/Account.swift's doc comment —
// `Blockchain` carries no curve/derivation-path logic, and picking the
// right ones for a chain is "whichever `KeyProvider` conformer constructs
// the `Account`"'s job). Tests that need a software-sourced `Account`
// build one directly here, via `Account`'s internal initializer (visible
// through `@testable import`) plus a freshly generated key.

import Foundation
@testable import WalletKit

enum TestAccountFactory {
    /// Builds a software-sourced `Account` for `blockchain`, deriving a
    /// fresh key with `curve` at `derivationPath`.
    static func makeAccount(
        blockchain: Blockchain,
        curve: Curve,
        derivationPath: DerivationPath
    ) throws -> Account {
        let seed = Mnemonic.generate().toSeed()
        let key = try seed.masterKey(curve: curve).derive(derivationPath)
        return Account(
            blockchain: blockchain,
            derivationPath: derivationPath,
            curve: curve,
            source: .software,
            publicKey: key.publicKey
        )
    }

    /// The standard `m/44'/coinType'/account'/0/0` path for secp256k1-based
    /// chains (Bitcoin, Ethereum, Tron), which mix hardened/non-hardened
    /// segments per BIP44.
    static func bip44Path(
        coinType: UInt32,
        account: UInt32 = 0
    ) -> DerivationPath {
        DerivationPath(segments: [
            Segment(index: 44, hardened: true),
            Segment(index: coinType, hardened: true),
            Segment(index: account, hardened: true),
            Segment(index: 0, hardened: false),
            Segment(index: 0, hardened: false)
        ])
    }

    /// The fully-hardened `m/44'/coinType'/account'/0'/0'` path for
    /// ed25519-based chains (Solana, Cardano, Sui) — SLIP-0010 only
    /// supports hardened derivation.
    static func slip10Path(coinType: UInt32, account: UInt32 = 0) -> DerivationPath {
        DerivationPath(segments: [
            Segment(index: 44, hardened: true),
            Segment(index: coinType, hardened: true),
            Segment(index: account, hardened: true),
            Segment(index: 0, hardened: true),
            Segment(index: 0, hardened: true)
        ])
    }

    static func ethereumAccount(chainId: UInt64 = 1, account: UInt32 = 0) throws -> Account {
        try makeAccount(
            blockchain: .ethereum(chainId),
            curve: .secp256k1,
            derivationPath: bip44Path(coinType: 60, account: account)
        )
    }

    static func bitcoinAccount(account: UInt32 = 0) throws -> Account {
        try makeAccount(
            blockchain: .bitcoin,
            curve: .secp256k1,
            derivationPath: bip44Path(coinType: 0, account: account)
        )
    }

    static func solanaAccount(account: UInt32 = 0) throws -> Account {
        try makeAccount(
            blockchain: .solana,
            curve: .ed25519,
            derivationPath: slip10Path(coinType: 501, account: account)
        )
    }

    static func suiAccount(curve: Curve = .ed25519, account: UInt32 = 0) throws -> Account {
        try makeAccount(
            blockchain: .sui(curve),
            curve: curve,
            derivationPath: slip10Path(coinType: 784, account: account)
        )
    }
}
