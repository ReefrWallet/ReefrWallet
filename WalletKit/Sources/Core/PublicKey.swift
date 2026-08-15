//
//  PublicKey.swift
//  WalletKit
//
//  Created by Andrey Yurkevich on 16/08/2026.
//

import Foundation

public protocol PublicKeyProtocol: AnyObject {
    var curve: Curve { get }
    var rawBytes: Data { get }
    func verify(signature: Data, message: Data) -> Bool
}

public final class PublicKey: PublicKeyProtocol {
    let raw: PublicKeyFfi

    init(raw: PublicKeyFfi) {
        self.raw = raw
    }

    public var curve: Curve { raw.curve() }
    public var rawBytes: Data { raw.rawBytes() }

    public func verify(signature: Data, message: Data) -> Bool {
        raw.verify(signature: signature, message: message)
    }
}
