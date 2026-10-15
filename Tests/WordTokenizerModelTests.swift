// Unit tests for `WordTokenizerModel`'s editing logic: no SwiftUI types
// are involved, so these run against the plain array of entries.

import Foundation
import Testing
import WalletKit
@testable import ReefrWallet

@MainActor
struct WordTokenizerModelTests {
    @Test
    func lettersThenSpaceCommitsAToken() {
        let model = WordTokenizerModel(wordlist: .english)
        let id = model.insertEditor(at: 0)

        model.update(editorText: "abandon ", at: id)

        #expect(model.entries.count == 2)
        #expect(model.entries[0].text == "abandon")
        if case .word = model.entries[0] {
            // committed
        } else {
            Issue.record("expected first entry to be a committed word")
        }
        #expect(model.phrase == "abandon ")
    }

    @Test
    func aSpaceKeepsTheNextEditorReadyForTyping() {
        let model = WordTokenizerModel(wordlist: .english)
        let firstEditorId = model.entries[0].id

        // The trailing editor keeps the same id as the editor it
        // replaces — that's the identity SwiftUI's focused `TextField`
        // already has. Handing it to the committed word instead (its
        // old behavior) morphs a focused `TextField` into a `Button`
        // under the same id, which drops focus mid-transition.
        let firstResult = model.update(editorText: "abandon ", at: firstEditorId)

        #expect(firstResult?.editorId == firstEditorId)
        #expect(firstResult?.didCommitWord == true)

        guard let secondEditorId = firstResult?.editorId else {
            Issue.record("expected an editor after committing the first word")
            return
        }

        model.update(editorText: "ability ", at: secondEditorId)

        #expect(model.phrase == "abandon ability ")
        #expect(model.entries.count == 3)
        if case .editor = model.entries[2] {
            // ready for the next word
        } else {
            Issue.record("expected a trailing editor")
        }
    }

    @Test
    func disallowedCharactersAreDropped() {
        let model = WordTokenizerModel(wordlist: .english)
        let id = model.insertEditor(at: 0)

        model.update(editorText: "ab1and!on", at: id)

        #expect(model.entries.count == 1)
        #expect(model.entries[0].text == "abandon")
    }

    @Test
    func pastingATwelveWordPhraseYieldsTwelveTokens() {
        let model = WordTokenizerModel(wordlist: .english)
        let id = model.insertEditor(at: 0)
        let pasted = Mnemonic.generate(wordCount: .`12`).phrase

        // Every segment but the last commits immediately; the trailing
        // word (no trailing space in `pasted`) stays in the editor until
        // it loses focus, same as a user finishing a paste and tapping
        // away.
        model.update(editorText: pasted, at: id)
        model.commitEditor()

        let words = model.entries.filter { entry in
            if case .word = entry {
                return true
            }

            return false
        }
        #expect(words.count == 12)
        #expect(model.phrase == pasted)
    }

    @Test
    func clearingAWordAndCommittingRemovesItAndShiftsTheRest() {
        let model = WordTokenizerModel(wordlist: .english)
        model.load(phrase: "abandon ability able")
        let middleId = model.entries[1].id

        model.beginEditing(at: middleId)
        model.update(editorText: "", at: middleId)
        model.commitEditor()

        #expect(model.entries.map(\.text) == ["abandon", "able"])
    }

    @Test
    func moveReordersAndPhraseReflectsIt() {
        let model = WordTokenizerModel(wordlist: .english)
        model.load(phrase: "abandon ability able")

        model.move(from: 0, to: 2)

        #expect(model.phrase == "ability able abandon")
    }

    @Test
    func loadThenPhraseRoundTripsAGeneratedMnemonic() {
        let model = WordTokenizerModel(wordlist: .english)
        let generated = Mnemonic.generate(wordCount: .`24`).phrase

        model.load(phrase: generated)

        #expect(model.phrase == generated)
    }

    @Test
    func generatedPhraseWordsAreValidAgainstTheWordlist() {
        let model = WordTokenizerModel(wordlist: .english)
        let generated = Mnemonic.generate(wordCount: .`24`).phrase
        model.load(phrase: generated)

        let index = WordlistIndex.index(for: .english)
        for entry in model.entries {
            #expect(index.contains(entry.text))
        }
    }

    @Test
    func anOffWordlistWordReportsInvalid() {
        let index = WordlistIndex.index(for: .english)

        #expect(!index.contains("notarealbip39word"))
    }
}
