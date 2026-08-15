//
//  ExtendedKey.swift
//  WalletKit
//
//  DESIGN SPEC — not generated code. See Walletkit/Docs/Overview.md for
//  module-level notes and architecture.
//

public protocol ExtendedKeyProtocol: AnyObject {
    var curve: Curve { get }
    var scheme: DerivationScheme { get }
    var depth: UInt8 { get }
    var childIndex: UInt32 { get }
    var isHardened: Bool { get }
    var canDerivePrivate: Bool { get }

    func derive(_ path: DerivationPath) throws -> ExtendedKey
    func deriveChild(index: UInt32, hardened: Bool) throws -> ExtendedKey

    var publicKey: PublicKey { get }
    func privateKey() throws -> PrivateKey

    func serializedPublic() -> String
    func serializedPrivate() throws -> String
}

/// A node in an HD key tree. Produced by `Seed.masterKey`, `Wallet.account`,
/// manual derivation, or by importing a serialized xpub/xprv-style string.
public final class ExtendedKey: ExtendedKeyProtocol {
    /// Imports a serialized extended key string. `curve` disambiguates
    /// formats that don't self-describe their curve.
    public static func fromSerialized(_ string: String, curve: Curve) throws -> ExtendedKey {
        fatalError("spec only")
    }

    public var curve: Curve { fatalError("spec only") }
    public var scheme: DerivationScheme { fatalError("spec only") }
    public var depth: UInt8 { fatalError("spec only") }
    public var childIndex: UInt32 { fatalError("spec only") }
    public var isHardened: Bool { fatalError("spec only") }

    /// False for keys derived from a public-only (watch-only) parent.
    public var canDerivePrivate: Bool { fatalError("spec only") }

    /// Derives a descendant by full path. Throws `.invalidDerivationPath`
    /// on malformed segments or if a non-hardened step is requested past a
    /// public-only node without a private key available.
    public func derive(_ path: DerivationPath) throws -> ExtendedKey {
        fatalError("spec only")
    }

    public func deriveChild(index: UInt32, hardened: Bool) throws -> ExtendedKey {
        fatalError("spec only")
    }

    public var publicKey: PublicKey { fatalError("spec only") }

    /// Throws `.keyNotFound` if this node is public-only (watch-only).
    public func privateKey() throws -> PrivateKey {
        fatalError("spec only")
    }

    /// Chain-appropriate public serialization (e.g. an "xpub"-style string).
    public func serializedPublic() -> String {
        fatalError("spec only")
    }

    /// Chain-appropriate private serialization (e.g. an "xprv"-style
    /// string). Sensitive — explicit backup/export use only.
    public func serializedPrivate() throws -> String {
        fatalError("spec only")
    }
}
