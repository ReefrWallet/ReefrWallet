//
//  WordTokenizerModel.swift
//  Reefr Wallet
//
//  Created by Andrey Yurkevich on 22.09.26.
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import Observation
import WalletKit

/// Editing state for a `WordTokenizerView`: an ordered list of committed
/// words plus, at most, a single in-progress editor standing in for the
/// caret. Modeling both as entries in one array means "the caret sits in
/// place of the next token" and "words shift" both fall out of plain
/// array mutation, with no separate cursor-position bookkeeping.
@MainActor @Observable
final class WordTokenizerModel {
    enum Entry: Identifiable {
        case editor(id: UUID, text: String)
        case word(id: UUID, text: String)

        var id: UUID {
            switch self {
            case .editor(let id, _): id
            case .word(let id, _): id
            }
        }

        var text: String {
            switch self {
            case .editor(_, let text): text
            case .word(_, let text): text
            }
        }
    }

    private(set) var entries: [Entry] = []
    private var index: WordlistIndex

    init(wordlist: Wordlist) {
        self.entries = [.editor(id: UUID(), text: "")]
        self.index = WordlistIndex.index(for: wordlist)
    }
}

extension WordTokenizerModel {
    /// The current phrase, as the space-joined text of every entry.
    var phrase: String {
        entries.map(\.text).joined(separator: " ")
    }

    /// Turns the `.word` at `id` into an `.editor` carrying its text,
    /// committing any editor already open elsewhere first.
    func beginEditing(at id: UUID) {
        commitEditor()

        guard let position = entries.firstIndex(where: { $0.id == id }),
              case let .word(_, text) = entries[position] else {
            return
        }

        entries[position] = .editor(id: id, text: text)
    }

    /// Commits the single open `.editor`, if any: non-empty text becomes
    /// a `.word`, empty text is removed outright (a whole-word delete +
    /// blur destroys the token, and later words shift left).
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

    /// Rebuilds `entries` from an externally-set phrase, discarding any
    /// in-progress edit.
    func load(phrase: String) {
        let words = phrase
            .split(whereSeparator: \.isWhitespace)
            .map { Entry.word(id: UUID(), text: String($0)) }

        entries = words.isEmpty ? [.editor(id: UUID(), text: "")] : words
    }

    /// Inserts a fresh empty `.editor` at `index` — the caret, including
    /// between two existing words — committing any open editor first.
    /// Returns the new editor's id so callers can focus it.
    @discardableResult
    func insertEditor(at index: Int) -> UUID {
        commitEditor()

        let id = UUID()
        let clampedIndex = min(max(index, 0), entries.count)
        entries.insert(.editor(id: id, text: ""), at: clampedIndex)
        return id
    }

    /// Reorders `entries` for a drag: moves the entry at `source` so it
    /// lands at `destination`.
    func move(from source: Int, to destination: Int) {
        guard entries.indices.contains(source) else {
            return
        }

        let entry = entries.remove(at: source)
        let clampedDestination = min(max(destination, 0), entries.count)
        entries.insert(entry, at: clampedDestination)
    }

    /// Switches the wordlist used to filter future keystrokes. Already
    /// committed words are left untouched — their color is derived on
    /// render, not stored, so it updates on its own.
    func setWordlist(_ wordlist: Wordlist) {
        index = WordlistIndex.index(for: wordlist)
    }

    /// The input gate for the `.editor` at `id`: lowercases `text`, drops
    /// any character that isn't whitespace or in the wordlist's allowed
    /// character set, then splits on whitespace. Every segment but the
    /// last commits as a `.word`; the last stays in the editor. This makes
    /// space-to-commit and pasting a whole recovery phrase the same code
    /// path.
    ///
    /// - Note: The trailing editor always keeps `id` — the identity the
    ///   focused `TextField` already has — instead of handing it to the
    ///   first committed word. Newly committed words get fresh ids. If the
    ///   focused editor's identity morphed into a `.word` (a `TextField`
    ///   becoming a `Button` under the same id), SwiftUI's focus system
    ///   drops focus mid-transition, deleting the new editor before it's
    ///   ever used.
    ///
    ///   `didCommitWord` tells the caller a word just committed out from
    ///   under this exact editor, clearing its text: on macOS, an
    ///   actively-focused `TextField`'s own AppKit-backed field editor
    ///   doesn't reliably pick up a value this much shorter than what
    ///   was just typed, and keeps showing (and appending to) the raw
    ///   keystrokes instead. The caller uses this to force that one
    ///   `TextField` to be rebuilt fresh instead of relying on the
    ///   binding alone.
    @discardableResult
    func update(editorText text: String, at id: UUID) -> (editorId: UUID, didCommitWord: Bool)? {
        guard let position = entries.firstIndex(where: { $0.id == id }),
              case .editor = entries[position] else {
            return nil
        }

        let filtered = text.lowercased().filter { $0.isWhitespace || index.isAllowed($0) }

        let endsWithWhitespace = filtered.last?.isWhitespace ?? false
        var segments = filtered.split(whereSeparator: \.isWhitespace).map(String.init)
        let tail = endsWithWhitespace ? "" : (segments.popLast() ?? "")

        let committed = segments.map { Entry.word(id: UUID(), text: $0) }

        let replacement = committed + [Entry.editor(id: id, text: tail)]

        entries.replaceSubrange(position...position, with: replacement)
        return (id, !committed.isEmpty)
    }
}
