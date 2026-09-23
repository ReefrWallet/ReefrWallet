//
//  WordlistIndex.swift
//  Reefr Wallet
//
//  Created by Andrey Yurkevich on 22.09.26.
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import WalletKit

/// Fast membership/character lookups over a `Wordlist`'s 2048 words.
///
/// Building `words`/`allowedCharacters` walks all 2048 words, so instances
/// are cached per `Wordlist` rather than rebuilt on every keystroke.
struct WordlistIndex {
    let allowedCharacters: Set<Character>
    let words: Set<String>

    init(wordlist: Wordlist) {
        let words = wordlist.words
        self.words = Set(words)
        self.allowedCharacters = Set(words.joined())
    }
}

extension WordlistIndex {
    @MainActor private static var cache: [Wordlist: WordlistIndex] = [:]

    @MainActor static func index(for wordlist: Wordlist) -> WordlistIndex {
        if let cached = cache[wordlist] {
            return cached
        }

        let index = WordlistIndex(wordlist: wordlist)
        cache[wordlist] = index
        return index
    }

    func contains(_ word: String) -> Bool {
        words.contains(word)
    }

    func isAllowed(_ character: Character) -> Bool {
        allowedCharacters.contains(character)
    }
}
