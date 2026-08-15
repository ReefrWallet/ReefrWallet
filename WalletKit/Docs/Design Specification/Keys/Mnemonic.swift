//
//  Mnemonic.swift
//  WalletKit
//
//  DESIGN SPEC — not generated code. See Walletkit/Docs/Overview.md for
//  module-level notes and architecture.
//

public protocol MnemonicProtocol: AnyObject {
    var phrase: String { get }
    var wordCount: MnemonicWordCount { get }
    var wordlist: Wordlist { get }
    func toSeed(passphrase: String) -> Seed
}

/// A BIP39 mnemonic. Holds the recovery phrase in Rust-managed, zeroized
/// memory; the phrase is only copied across the FFI boundary when `.phrase`
/// is read explicitly (e.g. to display it once during backup).
public final class Mnemonic: MnemonicProtocol {
    public static func generate(
        wordCount: MnemonicWordCount = .words24,
        wordlist: Wordlist = .english
    ) -> Mnemonic {
        fatalError("spec only")
    }

    /// Validates the BIP39 checksum; throws `.invalidMnemonic` on failure.
    public static func fromPhrase(
        _ phrase: String,
        wordlist: Wordlist = .english
    ) throws -> Mnemonic {
        fatalError("spec only")
    }

    public var phrase: String { fatalError("spec only") }
    public var wordCount: MnemonicWordCount { fatalError("spec only") }
    public var wordlist: Wordlist { fatalError("spec only") }

    public func toSeed(passphrase: String = "") -> Seed {
        fatalError("spec only")
    }
}
