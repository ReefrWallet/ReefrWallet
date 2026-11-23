//
//  HyperliquidResponses.swift
//  Reefr Wallet
//
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import Foundation

/// `/info` response shapes, decoded leniently: amounts are decimal strings.
enum Hyperliquid {
    /// A decimal sent as a string, e.g. `"1015.86472554"`.
    struct Amount: Codable, Equatable, Sendable {
        let value: Decimal

        init(_ value: Decimal) {
            self.value = value
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.singleValueContainer()
            let string = try container.decode(String.self)

            guard let value = Decimal(string: string, locale: Locale(identifier: "en_US_POSIX")) else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "not a decimal: \(string)")
            }

            self.value = value
        }

        func encode(to encoder: any Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encode("\(value)")
        }
    }

    struct BorrowLendUserState: Decodable, Sendable {
        struct Side: Decodable, Sendable {
            let value: Amount
        }

        struct TokenState: Decodable, Sendable {
            let borrow: Side
            let supply: Side
        }

        /// By spot token index.
        let tokens: [Int: TokenState]

        private enum CodingKeys: String, CodingKey {
            case tokenToState
        }

        init(tokens: [Int: TokenState]) {
            self.tokens = tokens
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            var pairs = try container.nestedUnkeyedContainer(forKey: .tokenToState)
            var tokens: [Int: TokenState] = [:]

            while !pairs.isAtEnd {
                var pair = try pairs.nestedUnkeyedContainer()
                let token = try pair.decode(Int.self)
                tokens[token] = try pair.decode(TokenState.self)
            }

            self.tokens = tokens
        }
    }

    struct ClearinghouseState: Decodable, Sendable {
        struct AssetPosition: Decodable, Sendable {
            let position: Position
        }

        struct Leverage: Decodable, Sendable {
            let type: String
        }

        struct MarginSummary: Decodable, Sendable {
            let accountValue: Amount
        }

        struct Position: Decodable, Sendable {
            let coin: String
            let leverage: Leverage
            let marginUsed: Amount
            let szi: Amount
            let unrealizedPnl: Amount
        }

        let assetPositions: [AssetPosition]
        let marginSummary: MarginSummary
    }

    struct DelegatorSummary: Decodable, Sendable {
        let delegated: Amount
        let totalPendingWithdrawal: Amount
        let undelegated: Amount

        var total: Decimal {
            delegated.value + undelegated.value + totalPendingWithdrawal.value
        }
    }

    struct PerpDex: Decodable, Sendable {
        let name: String
    }

    struct PerpMeta: Decodable, Sendable {
        struct Asset: Decodable, Sendable {
            let name: String
        }

        let collateralToken: Int
        let universe: [Asset]

        /// The dex the meta belongs to, from its coins' `dex:` prefix; `""` for the first dex.
        var dex: String? {
            universe.first.map { $0.name.contains(":") ? String($0.name.prefix { $0 != ":" }) : "" }
        }
    }

    struct SpotBalance: Decodable, Sendable {
        let coin: String
        let hold: Amount
        /// Absent on some entries, e.g. outcome holdings like `+1230`.
        let token: Int?
        let total: Amount
    }

    struct SpotClearinghouseState: Decodable, Sendable {
        let balances: [SpotBalance]
    }

    struct SpotMetaAndAssetCtxs: Decodable, Sendable {
        /// Matched to pairs by `coin`, not position: the list also holds outcome markets.
        struct AssetCtx: Decodable, Sendable {
            let coin: String
            let markPx: Amount?
        }

        struct Meta: Decodable, Sendable {
            let tokens: [Token]
            let universe: [Pair]
        }

        struct Pair: Decodable, Sendable {
            let name: String
            /// `[base, quote]` token indices.
            let tokens: [Int]
        }

        struct Token: Decodable, Sendable {
            let index: Int
            let name: String
        }

        let contexts: [AssetCtx]
        let meta: Meta

        init(contexts: [AssetCtx], meta: Meta) {
            self.contexts = contexts
            self.meta = meta
        }

        init(from decoder: any Decoder) throws {
            var container = try decoder.unkeyedContainer()
            meta = try container.decode(Meta.self)
            contexts = try container.decode([AssetCtx].self)
        }
    }

    struct VaultEquity: Decodable, Sendable {
        let equity: Amount
        let vaultAddress: String
    }
}
