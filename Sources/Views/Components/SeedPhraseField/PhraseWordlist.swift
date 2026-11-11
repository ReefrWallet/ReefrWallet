//
//  PhraseWordlist.swift
//  Reefr Wallet
//
//  Created by Andrey Yurkevich on 11.11.26.
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import WalletKit

/// The wordlist a recovery phrase is checked against.
enum PhraseWordlist: Hashable {
    case bip39(Wordlist)
    case slip39

    var words: [String] {
        switch self {
        case let .bip39(wordlist): wordlist.words
        case .slip39: Slip39.words
        }
    }
}

extension WordlistIndex {
    @MainActor private static var phraseCache: [PhraseWordlist: WordlistIndex] = [:]

    @MainActor static func index(for wordlist: PhraseWordlist) -> WordlistIndex {
        if let cached = phraseCache[wordlist] {
            return cached
        }

        let index = WordlistIndex(words: wordlist.words)
        phraseCache[wordlist] = index
        return index
    }
}
