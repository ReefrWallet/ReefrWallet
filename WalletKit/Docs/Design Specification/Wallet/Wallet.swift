//
//  Wallet.swift
//  WalletKit
//
//  DESIGN SPEC — not generated code. See Walletkit/Docs/Overview.md for
//  module-level notes and architecture.
//

import Foundation

/// High-level convenience type tying mnemonic + seed + derivation together.
/// This is the type most GUI code should hold onto day-to-day; the
/// lower-level types above remain available for advanced/manual use.
public protocol WalletProtocol: KeyProvider {
    var mnemonic: Mnemonic { get }

    func derive(_ path: DerivationPath, curve: Curve) throws -> ExtendedKey

    func exportBackup() -> WalletBackup
    func exportEncryptedBackup(password: String) throws -> Data
}

public final class Wallet: WalletProtocol {
    public static func create(wordCount: MnemonicWordCount = .words24) -> Wallet {
        fatalError("spec only")
    }

    /// Throws `.invalidMnemonic` on a bad checksum/phrase.
    public static func restore(phrase: String, passphrase: String = "") throws -> Wallet {
        fatalError("spec only")
    }

    /// Throws `.decryptionFailed` on a wrong password or corrupt blob.
    public static func restoreEncrypted(data: Data, password: String) throws -> Wallet {
        fatalError("spec only")
    }

    public var mnemonic: Mnemonic { fatalError("spec only") }
    public var source: KeySource { .software }

    public func publicKey(path: DerivationPath, curve: Curve) async throws -> PublicKey {
        fatalError("spec only")
    }

    /// Derives the standard account root for a chain
    /// (`m/44'|purpose'/coin_type'/account'`) using that chain's registered
    /// curve and scheme automatically, and returns it as a source-agnostic
    /// `Account`. For the actual signing key, call `derive(_:curve:)` with
    /// the same path.
    public func account(_ blockchain: Blockchain, account: UInt32 = 0) async throws -> Account {
        fatalError("spec only")
    }

    /// Manual/advanced derivation for callers that need a non-standard
    /// path, or need the actual `ExtendedKey`/`PrivateKey` to sign with.
    /// Software-only — there is no hardware equivalent of exporting key
    /// material, by design.
    public func derive(_ path: DerivationPath, curve: Curve) throws -> ExtendedKey {
        fatalError("spec only")
    }

    public func exportBackup() -> WalletBackup {
        fatalError("spec only")
    }

    public func exportEncryptedBackup(password: String) throws -> Data {
        fatalError("spec only")
    }
}
