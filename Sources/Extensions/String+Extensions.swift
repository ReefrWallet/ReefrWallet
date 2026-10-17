//
//  String+Extensions.swift
//  ReefrWallet
//
//  Created by Andrey Yurkevich on 20/08/2026.
//

extension String {
    static let dot = "•"

    /// `0x71C7656EC7ab88b098defB751B7401B5f6d8976F` → `0x71C7…976F`.
    func shortened(prefix: Int = 6, suffix: Int = 4) -> String {
        guard count > prefix + suffix + 1 else {
            return self
        }

        return "\(self.prefix(prefix))…\(self.suffix(suffix))"
    }
}
