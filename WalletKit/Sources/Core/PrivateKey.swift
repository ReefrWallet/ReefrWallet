//
//  PrivateKey.swift
//  WalletKit
//
//  Created by Andrey Yurkevich on 16/08/2026.
//

import Foundation

public protocol PrivateKeyProtocol: AnyObject {
    var curve: Curve { get }
    var publicKey: PublicKey { get }
    func sign(message: Data) throws -> Data
}

public final class PrivateKey: PrivateKeyProtocol {
    let raw: PrivateKeyFfi

    init(raw: PrivateKeyFfi) {
        self.raw = raw
    }

    /// Imports a private key directly from raw bytes — e.g. an externally
    /// held key, or (in tests) a shared test vector — bypassing
    /// mnemonic/BIP32 derivation entirely.
    ///
    /// Throws `.signingFailed` if `rawBytes.count != 32`, or (secp256k1
    /// only) if the 32 bytes aren't a valid scalar in the curve's order.
    public init(curve: Curve, rawBytes: Data) throws {
        raw = try remappingWalletKitError { try PrivateKeyFfi.fromRawBytes(curve: curve, rawBytes: rawBytes) }
    }

    public var curve: Curve { raw.curve() }
    public var publicKey: PublicKey { PublicKey(raw: raw.publicKey()) }

    public func sign(message: Data) throws -> Data {
        try remappingWalletKitError { try raw.sign(message: message) }
    }
}
