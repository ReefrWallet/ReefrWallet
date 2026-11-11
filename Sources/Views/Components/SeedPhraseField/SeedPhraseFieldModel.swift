//
//  SeedPhraseFieldModel.swift
//  Reefr Wallet
//
//  Created by Andrey Yurkevich on 11.11.26.
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import Foundation
import Observation

/// Editing state of a `SeedPhraseField`: the phrase in order, with at most
/// one in-progress editor sitting at the position its word will take.
///
/// A word becomes a chip only once it is complete (space typed, pasted
/// whole, or focus left the field). Input that would exceed `wordCount` is
/// rejected as a whole, never truncated.
@MainActor @Observable
final class SeedPhraseFieldModel {
    enum Entry: Equatable, Identifiable {
        case editor(id: UUID, text: String)
        case word(id: UUID, text: String)

        var id: UUID {
            switch self {
            case let .editor(id, _): id
            case let .word(id, _): id
            }
        }

        var isEditor: Bool {
            if case .editor = self {
                return true
            }

            return false
        }

        var text: String {
            switch self {
            case let .editor(_, text): text
            case let .word(_, text): text
            }
        }
    }

    enum InputError: Equatable {
        case pasteRejected(count: Int)
        case tooManyWords(count: Int)
        case unsupportedLength(count: Int)
    }

    nonisolated static let supportedSlip39WordCounts = [20, 33]

    private(set) var entries: [Entry] = [.editor(id: UUID(), text: "")]
    private(set) var inputError: InputError?

    var wordCount: Int {
        didSet { reevaluateError() }
    }

    private var index: WordlistIndex
    private(set) var wordlist: PhraseWordlist

    init(wordCount: Int, wordlist: PhraseWordlist) {
        self.wordCount = wordCount
        self.wordlist = wordlist
        index = WordlistIndex.index(for: wordlist)
    }
}

// MARK: - Reading

extension SeedPhraseFieldModel {
    /// The phrase in order, the in-progress word included.
    var phrase: String {
        entries.map(\.text).filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// Words entered, the in-progress one included.
    var totalWordCount: Int {
        entries.filter { !$0.text.isEmpty }.count
    }

    /// Exactly `wordCount` words, all in the wordlist, nothing rejected.
    var isComplete: Bool {
        inputError == nil
            && totalWordCount == wordCount
            && entries.allSatisfy { $0.text.isEmpty || index.contains($0.text) }
    }

    /// Whether the editor is shown: not once every word is a chip.
    var hasEditor: Bool {
        entries.contains { entry in
            if case .editor = entry {
                return true
            }

            return false
        }
    }

    /// Whether the open editor holds text.
    var hasEditorWithText: Bool {
        entries.contains { entry in
            if case let .editor(_, text) = entry {
                return !text.isEmpty
            }

            return false
        }
    }

    func isValid(_ word: String) -> Bool {
        index.contains(word)
    }

    /// The number of chips (and editor text) before `id`, for numbering.
    func position(of id: UUID) -> Int? {
        entries.firstIndex { $0.id == id }
    }
}

// MARK: - Editing

extension SeedPhraseFieldModel {
    /// Turns the `.word` at `id` into the editor, committing any editor
    /// already open.
    func beginEditing(at id: UUID) {
        commitEditor()

        guard let position = entries.firstIndex(where: { $0.id == id }),
              case let .word(_, text) = entries[position] else {
            return
        }

        entries[position] = .editor(id: id, text: text)
    }

    /// Commits the open editor: text becomes a word, an empty editor goes.
    func commitEditor() {
        guard let position = entries.firstIndex(where: { entry in
            if case .editor = entry {
                return true
            }

            return false
        }) else {
            return
        }

        switch entries[position] {
        case let .editor(id, text) where !text.isEmpty:
            entries[position] = .word(id: id, text: text)
        case .editor:
            entries.remove(at: position)
        case .word:
            break
        }
    }

    /// Backspace on an empty editor: removes it and opens the word before
    /// it. Returns that word's id.
    @discardableResult
    func editPreviousWord(from id: UUID) -> UUID? {
        guard let position = entries.firstIndex(where: { $0.id == id }),
              position > entries.startIndex,
              case .word = entries[position - 1] else {
            return nil
        }

        let previousId = entries[position - 1].id
        entries.remove(at: position)
        beginEditing(at: previousId)
        return previousId
    }

    /// Puts an empty editor at `position` (the caret between two chips),
    /// committing any open editor first. Returns its id.
    @discardableResult
    func insertEditor(at position: Int) -> UUID {
        commitEditor()
        let id = UUID()
        entries.insert(.editor(id: id, text: ""), at: min(max(position, 0), entries.count))
        reevaluateError()
        return id
    }

    /// Replaces the contents from an external phrase, dropping any edit.
    func load(phrase: String) {
        let words = phrase.split(whereSeparator: \.isWhitespace).map { Entry.word(id: UUID(), text: String($0)) }
        entries = words.isEmpty ? [.editor(id: UUID(), text: "")] : words
        inputError = nil
        reevaluateError()
    }

    /// Deletes the whole word at `id`; later words renumber.
    func remove(id: UUID) {
        guard let position = entries.firstIndex(where: { $0.id == id }) else {
            return
        }

        entries.remove(at: position)

        if entries.isEmpty {
            entries = [.editor(id: UUID(), text: "")]
        }

        inputError = nil
        reevaluateError()
    }

    func setWordlist(_ wordlist: PhraseWordlist) {
        self.wordlist = wordlist
        index = WordlistIndex.index(for: wordlist)
        reevaluateError()
    }

    /// The input gate for the editor at `id`. Lowercases, drops characters
    /// outside the wordlist, splits on whitespace; every segment but the
    /// last becomes a word at the editor's position and the last stays in
    /// the editor. A result over `wordCount` words is rejected whole.
    ///
    /// - Parameter renewsEditor: Gives the editor a new identity after a
    ///   commit, so UIKit builds a fresh text field instead of resyncing one.
    /// - Returns: The editor's id and whether a word committed, or `nil`
    ///   when the edit was ignored or rejected.
    @discardableResult
    func update(
        editorText text: String,
        at id: UUID,
        renewsEditor: Bool = false
    ) -> (editorId: UUID, didCommitWord: Bool)? {
        guard let position = entries.firstIndex(where: { $0.id == id }),
              case .editor = entries[position] else {
            return nil
        }

        let filtered = text.lowercased().filter { $0.isWhitespace || index.isAllowed($0) }
        let endsWithWhitespace = filtered.last?.isWhitespace ?? false
        var segments = filtered.split(whereSeparator: \.isWhitespace).map(String.init)
        let tail = endsWithWhitespace ? "" : (segments.popLast() ?? "")
        let inserted = segments.count + (tail.isEmpty ? 0 : 1)
        let others = entries.enumerated().filter { $0.offset != position && !$0.element.text.isEmpty }.count

        guard others + inserted <= wordCount else {
            inputError = rejection(forPasted: inserted)
            return nil
        }

        inputError = nil

        let committed = segments.map { Entry.word(id: UUID(), text: $0) }
        let editorId = renewsEditor && !committed.isEmpty ? UUID() : id
        entries.replaceSubrange(position ... position, with: committed + [.editor(id: editorId, text: tail)])
        return (editorId, !committed.isEmpty)
    }
}

// MARK: - Errors

private extension SeedPhraseFieldModel {
    func rejection(forPasted count: Int) -> InputError {
        if wordlist == .slip39, !Self.supportedSlip39WordCounts.contains(count) {
            return .unsupportedLength(count: count)
        }

        return .pasteRejected(count: count)
    }

    /// A smaller count can leave extra words; a fitting count clears a
    /// rejection.
    func reevaluateError() {
        if totalWordCount > wordCount {
            inputError = .tooManyWords(count: totalWordCount)
            return
        }

        switch inputError {
        case .tooManyWords:
            inputError = nil
        case let .pasteRejected(count) where count <= wordCount:
            inputError = nil
        case let .unsupportedLength(count) where count <= wordCount && Self.supportedSlip39WordCounts.contains(count):
            inputError = nil
        default:
            break
        }
    }
}
