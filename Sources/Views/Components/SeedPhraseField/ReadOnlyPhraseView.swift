//
//  ReadOnlyPhraseView.swift
//  Reefr Wallet
//
//  Created by Andrey Yurkevich on 11.11.26.
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import SwiftUI

/// A recovery phrase as numbered, read-only chips.
struct ReadOnlyPhraseView: View {
    let phrase: String
    let wordlist: PhraseWordlist

    @State private var model: SeedPhraseFieldModel

    init(phrase: String, wordlist: PhraseWordlist) {
        self.phrase = phrase
        self.wordlist = wordlist
        _model = State(initialValue: SeedPhraseFieldModel(wordCount: 33, wordlist: wordlist))
    }

    var body: some View {
        SeedPhraseField(model: model, readOnly: true)
            .onChange(of: phrase, initial: true) { _, newValue in
                model.wordCount = newValue.split(whereSeparator: \.isWhitespace).count
                model.load(phrase: newValue)
            }
    }
}
