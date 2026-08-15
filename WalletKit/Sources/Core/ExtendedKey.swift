//
//  ExtendedKey.swift
//  WalletKit
//
//  Created by Andrey Yurkevich on 16/08/2026.
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

public final class ExtendedKey: ExtendedKeyProtocol {
    let raw: ExtendedKeyFfi

    init(raw: ExtendedKeyFfi) {
        self.raw = raw
    }

    public static func fromSerialized(_ string: String, curve: Curve) throws -> ExtendedKey {
        try remappingWalletKitError {
            ExtendedKey(raw: try ExtendedKeyFfi.fromSerialized(string: string, curve: curve))
        }
    }

    public var curve: Curve { raw.curve() }
    public var scheme: DerivationScheme { raw.scheme() }
    public var depth: UInt8 { raw.depth() }
    public var childIndex: UInt32 { raw.childIndex() }
    public var isHardened: Bool { raw.isHardened() }
    public var canDerivePrivate: Bool { raw.canDerivePrivate() }

    public func derive(_ path: DerivationPath) throws -> ExtendedKey {
        try remappingWalletKitError { ExtendedKey(raw: try raw.derive(path: path)) }
    }

    public func deriveChild(index: UInt32, hardened: Bool) throws -> ExtendedKey {
        try remappingWalletKitError { ExtendedKey(raw: try raw.deriveChild(index: index, hardened: hardened)) }
    }

    public var publicKey: PublicKey { PublicKey(raw: raw.publicKey()) }

    public func privateKey() throws -> PrivateKey {
        try remappingWalletKitError { PrivateKey(raw: try raw.privateKey()) }
    }

    public func serializedPublic() -> String {
        raw.serializedPublic()
    }

    public func serializedPrivate() throws -> String {
        try remappingWalletKitError { try raw.serializedPrivate() }
    }
}
