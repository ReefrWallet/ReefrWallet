//
//  KeyProvider.swift
//  WalletKit
//
//  Created by Andrey Yurkevich on 16/08/2026.
//

public enum KeySource: Equatable {
    case software
    case hardware(HardwareDeviceInfo)
}

public protocol KeyProvider: AnyObject {
    var source: KeySource { get }

    func publicKey(path: DerivationPath, curve: Curve) async throws -> PublicKey
    func account(_ blockchain: Blockchain, account: UInt32) async throws -> Account
}
