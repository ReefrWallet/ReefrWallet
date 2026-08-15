//
//  HardwareDevice.swift
//  WalletKit
//
//  DESIGN SPEC — not generated code. See Walletkit/Docs/Overview.md for
//  module-level notes and architecture.
//

public protocol HardwareDeviceProtocol: KeyProvider {
    var info: HardwareDeviceInfo { get }
    var isConnected: Bool { get }
    func disconnect() async
}

/// A connected hardware device, conforming to `KeyProvider` alongside
/// `Wallet` — `publicKey(path:curve:)` and `account(_:account:)` work the
/// same way callers expect from software, just backed by a device round
/// trip (and possibly a `HardwareDeviceDelegate` prompt) instead of local
/// derivation. Throws `.deviceLocked`, `.deviceDisconnected`, or
/// `.userRejectedOnDevice` as appropriate.
public final class HardwareDevice: HardwareDeviceProtocol {
    public var info: HardwareDeviceInfo { fatalError("spec only") }
    public var isConnected: Bool { fatalError("spec only") }
    public var source: KeySource { .hardware(info) }

    public func publicKey(path: DerivationPath, curve: Curve) async throws -> PublicKey {
        fatalError("spec only")
    }

    public func account(_ blockchain: Blockchain, account: UInt32 = 0) async throws -> Account {
        fatalError("spec only")
    }

    public func disconnect() async {
        fatalError("spec only")
    }
}
