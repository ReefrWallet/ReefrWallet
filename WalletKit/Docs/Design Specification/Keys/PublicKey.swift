//
//  PublicKey.swift
//  WalletKit
//
//  DESIGN SPEC — not generated code. See Walletkit/Docs/Overview.md for
//  module-level notes and architecture.
//

import Foundation

public protocol PublicKeyProtocol: AnyObject {
    var curve: Curve { get }
    var rawBytes: Data { get }
    func verify(signature: Data, message: Data) -> Bool
}

public final class PublicKey: PublicKeyProtocol {
    public var curve: Curve { fatalError("spec only") }

    /// Compressed SEC1 encoding for secp256k1, raw 32 bytes for ed25519.
    public var rawBytes: Data { fatalError("spec only") }

    public func verify(signature: Data, message: Data) -> Bool {
        fatalError("spec only")
    }
}
