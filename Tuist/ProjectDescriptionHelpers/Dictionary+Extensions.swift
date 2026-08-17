//
//  Dictionary+Extensions.swift
//  Reefr Wallet
//
//  Created by Andrey Yurkevich on 21.12.25.
//  Copyright © 2025 Reefr Wallet. All rights reserved.
//

import ProjectDescription

public extension Dictionary where Key == String, Value == Plist.Value {
    /// Merges two plist dictionaries.
    ///
    /// - Parameter other: The other plist dictionary to merge with.
    /// - Returns: A new plist dictionary containing the merged key-value pairs.
    func merging(with other: [String: Plist.Value]) -> [String: Plist.Value] {
        var merged = self

        for (key, value) in other {
            merged[key] = value
        }

        return merged
    }
}
