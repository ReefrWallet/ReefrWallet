// Unit tests for `SeedPhraseFieldModel`: no SwiftUI types are involved.

import Foundation
import Testing
import WalletKit
@testable import ReefrWallet

@MainActor
struct SeedPhraseFieldModelTests {
    private static let twelve = "abandon ability able about above absent absorb abstract absurd abuse access accident"

    private func model(count: Int = 12, wordlist: PhraseWordlist = .bip39(.english)) -> SeedPhraseFieldModel {
        SeedPhraseFieldModel(wordCount: count, wordlist: wordlist)
    }

    @Test
    func spaceCommitsAWordAndKeepsTheEditor() throws {
        let field = model()
        let id = field.entries[0].id

        let result = try #require(field.update(editorText: "abandon ", at: id))

        #expect(result.editorId == id)
        #expect(result.didCommitWord)
        #expect(field.entries.map(\.text) == ["abandon", ""])
    }

    @Test
    func leavingTheFieldCommitsTheWordBeingTyped() {
        let field = model()
        field.update(editorText: "abandon ability ab", at: field.entries[0].id)

        field.commitEditor()

        #expect(field.entries.map(\.text) == ["abandon", "ability", "ab"])
        #expect(!field.hasEditor)
    }

    @Test
    func exactLengthPasteWithoutTrailingSpaceIsComplete() {
        let field = model()
        field.update(editorText: Self.twelve, at: field.entries[0].id)

        #expect(field.phrase == Self.twelve)
        #expect(field.totalWordCount == 12)
        #expect(field.isComplete)
    }

    @Test
    func editingAMiddleWordKeepsTheOrder() throws {
        let field = model()
        field.load(phrase: Self.twelve)
        let third = field.entries[2].id

        field.beginEditing(at: third)
        field.update(editorText: "zoo", at: third)
        field.commitEditor()

        var expected = Self.twelve.split(separator: " ").map(String.init)
        expected[2] = "zoo"
        #expect(field.phrase == expected.joined(separator: " "))
    }

    @Test
    func pasteIntoAMiddleEditorInsertsInPlace() throws {
        let field = model()
        field.load(phrase: "abandon ability able")
        let id = field.insertEditor(at: 1)

        field.update(editorText: "zoo zone ", at: id)

        #expect(field.phrase == "abandon zoo zone ability able")
    }

    @Test
    func aCaretBetweenWordsChangesNothing() {
        let field = model()
        field.load(phrase: "abandon ability able")

        field.insertEditor(at: 2)

        #expect(field.phrase == "abandon ability able")
        #expect(field.totalWordCount == 3)
    }

    @Test
    func pasteOverTheCapIsRejectedWholeAndKeepsThePreviousInput() throws {
        let field = model(count: 12)
        field.load(phrase: "abandon ability able")
        let id = field.insertEditor(at: 3)
        let paste = Array(repeating: "zoo", count: 24).joined(separator: " ")

        let result = field.update(editorText: paste, at: id)

        #expect(result == nil)
        #expect(field.inputError == .pasteRejected(count: 24))
        #expect(field.phrase == "abandon ability able")
        #expect(!field.isComplete)
    }

    @Test
    func loweringTheCountKeepsEveryWordAndReportsTheOverflow() {
        let field = model(count: 12)
        field.load(phrase: Self.twelve)

        field.wordCount = 6
        #expect(field.inputError == .tooManyWords(count: 12))
        #expect(field.totalWordCount == 12)
        #expect(!field.isComplete)

        field.wordCount = 12
        #expect(field.inputError == nil)
        #expect(field.isComplete)
    }

    @Test
    func aWholePhraseWithTheWrongSelectedCountIsNotComplete() {
        let field = model(count: 24)
        field.load(phrase: Self.twelve)

        #expect(!field.isComplete)
    }

    @Test
    func unsupportedSlip39LengthIsReported() throws {
        let field = model(count: 20, wordlist: .slip39)
        let paste = Array(repeating: "academic", count: 59).joined(separator: " ")

        let result = field.update(editorText: paste, at: field.entries[0].id)

        #expect(result == nil)
        #expect(field.inputError == .unsupportedLength(count: 59))
    }

    @Test
    func removingAWordRenumbersTheRestAndClearsTheOverflow() throws {
        let field = model(count: 3)
        field.load(phrase: "abandon ability able about")
        #expect(field.inputError == .tooManyWords(count: 4))

        field.remove(id: field.entries[1].id)

        #expect(field.phrase == "abandon able about")
        #expect(field.inputError == nil)
    }

    @Test
    func backspaceOnAnEmptyEditorReopensThePreviousWord() throws {
        let field = model()
        field.update(editorText: "abandon ", at: field.entries[0].id)
        let editor = field.entries[1].id

        let reopened = try #require(field.editPreviousWord(from: editor))

        #expect(field.entries.count == 1)
        #expect(field.entries[0].id == reopened)
        #expect(field.entries[0].text == "abandon")
        #expect(field.hasEditor)
    }

    @Test
    func disallowedCharactersAreDropped() {
        let field = model()
        field.update(editorText: "ab1ando!n", at: field.entries[0].id)

        #expect(field.phrase == "abandon")
    }
}
