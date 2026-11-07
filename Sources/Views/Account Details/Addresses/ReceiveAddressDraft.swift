//
//  ReceiveAddressDraft.swift
//  Reefr Wallet
//
//  Created by Andrey Yurkevich on 07.11.26.
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import WalletKit

/// The Add Address sheet's state: which index it derives and what it tells the person.
struct ReceiveAddressDraft: Equatable {
    /// Consecutive unused addresses other wallets scan before they stop.
    static let gapLimit = 20

    enum Note: Equatable {
        case allListed
        case invalidIndex
        case lowestFree(index: UInt32)
        case next(index: UInt32, newest: UInt32)
        case custom(index: UInt32)
    }

    let rows: [ReceiveAddress]
    var isCustom = false
    var text = ""

    /// The index the sheet would add, or `nil` if it can't.
    var index: UInt32? {
        isCustom ? customIndex : suggestedIndex
    }

    var isAddEnabled: Bool {
        index != nil
    }

    /// `true` when a restore from the recovery phrase in another wallet could miss the address.
    var isPastGap: Bool {
        guard let index else {
            return false
        }

        return Int(index) > lastUsedIndex + Self.gapLimit
    }

    var note: Note {
        if isCustom {
            return customIndex.map(Note.custom(index:)) ?? .invalidIndex
        }

        guard let suggestedIndex else {
            return .allListed
        }

        guard let newest = rows.map(\.index).max(), suggestedIndex == newest + 1 else {
            return .lowestFree(index: suggestedIndex)
        }

        return .next(index: suggestedIndex, newest: newest)
    }

    /// The highest on-chain used index; `-1` if none is known.
    private var lastUsedIndex: Int {
        rows.filter { $0.isUsed == true }.map { Int($0.index) }.max() ?? -1
    }

    private var listed: Set<UInt32> {
        Set(rows.map(\.index))
    }

    private var suggestedIndex: UInt32? {
        CardanoAccountDescriptor.nextExternalIndex(after: listed)
    }

    private var customIndex: UInt32? {
        guard
            let value = UInt32(text.trimmingCharacters(in: .whitespaces)),
            value < CardanoAccountDescriptor.addressIndexLimit,
            !listed.contains(value)
        else {
            return nil
        }

        return value
    }
}
