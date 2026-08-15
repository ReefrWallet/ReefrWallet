//
//  ExtendedKey.swift
//  WalletKit
//
//  DESIGN SPEC — not generated code. See Walletkit/Docs/Overview.md for
//  module-level notes and architecture.
//

/// A node in an HD key tree. Produced by `Seed.masterKey`, `Wallet.account`,
/// manual derivation, or by importing a serialized xpub/xprv-style string.
public protocol ExtendedKeyProtocol: AnyObject {
    var curve: Curve { get }
    var scheme: DerivationScheme { get }
    var depth: UInt8 { get }
    var childIndex: UInt32 { get }
    var isHardened: Bool { get }
    /// False for keys derived from a public-only (watch-only) parent.
    var canDerivePrivate: Bool { get }

    /// Derives a descendant by full path. Throws `.invalidDerivationPath`
    /// on malformed segments or if a non-hardened step is requested past a
    /// public-only node without a private key available.
    func derive(_ path: DerivationPath) throws -> ExtendedKey
    func deriveChild(index: UInt32, hardened: Bool) throws -> ExtendedKey

    var publicKey: PublicKey { get }

    /// Throws `.keyNotFound` if this node is public-only (watch-only).
    func privateKey() throws -> PrivateKey

    /// Chain-appropriate public serialization (e.g. an "xpub"-style string).
    func serializedPublic() -> String

    /// Chain-appropriate private serialization (e.g. an "xprv"-style
    /// string). Sensitive — explicit backup/export use only.
    func serializedPrivate() throws -> String
}
