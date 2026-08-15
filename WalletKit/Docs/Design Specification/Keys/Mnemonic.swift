//
//  Mnemonic.swift
//  WalletKit
//
//  DESIGN SPEC — not generated code. See Walletkit/Docs/Overview.md for
//  module-level notes and architecture.
//

/// A BIP39 mnemonic. Holds the recovery phrase in Rust-managed, zeroized
/// memory; the phrase is only copied across the FFI boundary when `.phrase`
/// is read explicitly (e.g. to display it once during backup).
public protocol MnemonicProtocol: AnyObject {
    var phrase: String { get }
    var wordCount: MnemonicWordCount { get }
    var wordlist: Wordlist { get }
    func toSeed(passphrase: String) -> Seed

    /// Validates the BIP39 checksum; throws `.invalidMnemonic` on failure.
    static func fromPhrase(_ phrase: String, wordlist: Wordlist = .english) throws -> Mnemonic

    public static func generate(wordCount: MnemonicWordCount = .24, wordlist: Wordlist = .english) -> Mnemonic
}
