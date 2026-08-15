//
//  WalletBackup.swift
//  WalletKit
//
//  DESIGN SPEC — not generated code. See Walletkit/Docs/Overview.md for
//  module-level notes and architecture.
//

/// Plaintext backup payload — the phrase plus enough metadata to restore
/// deterministically. Callers decide how/where this is stored; WalletKit
/// never persists it itself.
public struct WalletBackup: Equatable {
    public let phrase: String
    public let wordlist: Wordlist
    public let hasPassphrase: Bool
    public let createdAt: UInt64 // unix seconds

    public init(phrase: String, wordlist: Wordlist, hasPassphrase: Bool, createdAt: UInt64) {
        self.phrase = phrase
        self.wordlist = wordlist
        self.hasPassphrase = hasPassphrase
        self.createdAt = createdAt
    }
}
