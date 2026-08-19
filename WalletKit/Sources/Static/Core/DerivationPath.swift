//
//  DerivationPath.swift
//  WalletKit
//
//  Created by Andrey Yurkevich on 16/08/2026.
//

import WalletKitRust

extension DerivationPath {
    /// Gets derivation path for given ``Blockchain`` and account index
    public init(_ blockchain: Blockchain, accountIndex: UInt64) throws {
        switch blockchain {
        case .ethereum:
            try self.init(string: "m/44'/60'/0'/0/\(accountIndex)")
        case let .sui(curve):
            switch curve {
            /// m/44'/784'/{account}'/0/0
            case .ed25519:
                try self.init(string: "m/44'/784'/0'/0'/\(accountIndex)'")
            /// m/54'/784'/{account}'/0'/0'
            case .secp256k1:
                try self.init(string: "m/54'/784'/0'/0/\(accountIndex)")
            }
        default:
            throw WalletKitError.internalError(message: "Unsupported blockchain: \(blockchain)")
        }
    }

    /// Parses a `m/44'/60'/0'/0/0`-style derivation path string.
    ///
    /// - Parameter string: The path string to parse. Must start with `m`
    ///   and have at least one `/`-separated segment; each segment is a
    ///   non-negative integer optionally suffixed with `'`, `h`, or `H` to
    ///   mark it as hardened.
    /// - Throws: ``WalletKitError/invalidDerivationPath(path:)`` if
    ///   `string` doesn't match that shape.
    public init(string: String) throws {
        var parts = string.split(separator: "/", omittingEmptySubsequences: false).map(String.init)

        guard !parts.isEmpty, parts.removeFirst() == "m" else {
            throw WalletKitError.invalidDerivationPath(path: string)
        }

        var segments: [Segment] = []

        for part in parts {
            guard !part.isEmpty else {
                throw WalletKitError.invalidDerivationPath(path: string)
            }
            let hardened = part.hasSuffix("'") || part.hasSuffix("h") || part.hasSuffix("H")
            let digits = hardened ? String(part.dropLast()) : part
            guard let index = UInt32(digits) else {
                throw WalletKitError.invalidDerivationPath(path: string)
            }

            segments.append(Segment(index: index, hardened: hardened))
        }

        guard !segments.isEmpty else {
            throw WalletKitError.invalidDerivationPath(path: string)
        }

        self.init(segments: segments)
    }

    /// The `m/44'/60'/0'/0/0`-style string representation of this path.
    public var string: String {
        var result = "m"

        for segment in segments {
            result += "/\(segment.index)"
            if segment.hardened {
                result += "'"
            }
        }

        return result
    }
}
