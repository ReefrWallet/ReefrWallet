//
//  Mnemonic.swift
//  WalletKit
//
//  Created by Andrey Yurkevich on 16/08/2026.
//

public protocol MnemonicProtocol: AnyObject {
    var phrase: String { get }
    var wordCount: MnemonicWordCount { get }
    var wordlist: Wordlist { get }
    func toSeed(passphrase: String) -> Seed
}

public final class Mnemonic: MnemonicProtocol {
    let raw: MnemonicFfi

    init(raw: MnemonicFfi) {
        self.raw = raw
    }

    public static func generate(wordCount: MnemonicWordCount = .words24, wordlist: Wordlist = .english) -> Mnemonic {
        Mnemonic(raw: MnemonicFfi.generate(wordCount: wordCount, wordlist: wordlist))
    }

    public static func fromPhrase(_ phrase: String, wordlist: Wordlist = .english) throws -> Mnemonic {
        try remappingWalletKitError {
            Mnemonic(raw: try MnemonicFfi.fromPhrase(phrase: phrase, wordlist: wordlist))
        }
    }

    public var phrase: String { raw.phrase() }
    public var wordCount: MnemonicWordCount { raw.wordCount() }
    public var wordlist: Wordlist { raw.wordlist() }

    public func toSeed(passphrase: String = "") -> Seed {
        Seed(raw: raw.toSeed(passphrase: passphrase))
    }
}

// MARK: - MnemonicWordCount

extension MnemonicWordCount: RawRepresentable {
    public typealias RawValue = UInt32

    public var rawValue: UInt32 {
        switch self {
        case .words12: return 12
        case .words15: return 15
        case .words18: return 18
        case .words21: return 21
        case .words24: return 24
        }
    }

    public init?(rawValue: UInt32) {
        switch rawValue {
        case 12: self = .words12
        case 15: self = .words15
        case 18: self = .words18
        case 21: self = .words21
        case 24: self = .words24
        default: return nil
        }
    }
}
