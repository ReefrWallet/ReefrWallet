//
//  Seed.swift
//  WalletKit
//
//  Created by Andrey Yurkevich on 16/08/2026.
//

import Foundation

public protocol SeedProtocol: AnyObject {
    func masterKey(curve: Curve) throws -> ExtendedKey
    func exportRaw() -> Data
}

public final class Seed: SeedProtocol {
    let raw: SeedFfi

    init(raw: SeedFfi) {
        self.raw = raw
    }

    public func masterKey(curve: Curve) throws -> ExtendedKey {
        ExtendedKey(raw: raw.masterKey(curve: curve))
    }

    public func exportRaw() -> Data {
        raw.exportRaw()
    }
}
