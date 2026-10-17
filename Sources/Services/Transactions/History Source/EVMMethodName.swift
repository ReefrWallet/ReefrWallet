//
//  EVMMethodName.swift
//  Reefr Wallet
//

import Foundation

/// Turns indexer method names (`transfer`, `swapExactETHForTokens(uint256,…)`) into list labels.
enum EVMMethodName {
    static func display(_ raw: String?, hasValue: Bool) -> String? {
        let name = raw?
            .split(separator: "(", maxSplits: 1)
            .first
            .map(String.init)?
            .trimmingCharacters(in: .whitespaces) ?? ""

        guard !name.isEmpty, !name.hasPrefix("0x") else {
            return hasValue ? "Transfer" : nil
        }

        return words(name).joined(separator: " ")
    }

    private static func words(_ name: String) -> [String] {
        var words: [String] = []
        var current = ""

        for character in name.replacingOccurrences(of: "_", with: " ") {
            if character == " " {
                words.append(current)
                current = ""
            } else if character.isUppercase, let last = current.last, last.isLowercase {
                words.append(current)
                current = String(character)
            } else {
                current.append(character)
            }
        }

        words.append(current)

        return words
            .filter { !$0.isEmpty }
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
    }
}
