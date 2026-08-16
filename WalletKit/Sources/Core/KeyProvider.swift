//
//  KeyProvider.swift
//  WalletKit
//
//  Created by Andrey Yurkevich on 16/08/2026.
//

/// Where an ``Account``'s signing key material actually lives.
public enum KeySource: Equatable {
    /// The key is derived and held in-app (e.g. from a ``Mnemonic``/``Seed``).
    case software

    /// The key lives on a connected hardware wallet, described by the
    /// associated device info.
    case hardware(HardwareDeviceInfo)
}

/// A source of public keys and accounts — either in-app key derivation
/// (software) or a connected hardware device.
///
/// ``HardwareDeviceProtocol`` conforms to this so hardware and software key
/// sources can be used interchangeably wherever an app only needs to read
/// public keys/addresses.
public protocol KeyProvider: AnyObject {
    /// Where this provider's key material lives.
    var source: KeySource { get }

    /// Reads the public key at `path` for `curve`.
    ///
    /// - Parameters:
    ///   - path: The derivation path to read the public key at.
    ///   - curve: The elliptic curve to derive under.
    /// - Returns: The public key at `path`.
    func publicKey(path: DerivationPath, curve: Curve) async throws -> PublicKey

    /// Builds the ``Account`` for `blockchain` at index `account`.
    ///
    /// - Parameters:
    ///   - blockchain: The blockchain to build the account for.
    ///   - account: The BIP44-style account index.
    /// - Returns: The resulting account, including its derived public key.
    func account(_ blockchain: Blockchain, account: UInt32) async throws -> Account
}
