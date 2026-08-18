//
//  EthereumABI.swift
//  WalletKit
//
//  Created by Andrey Yurkevich on 17/08/2026.
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import BigInt
import Foundation
import WalletKitRust

/// A parameter value for an ABI-encoded contract call. Covers the static
/// (fixed-width) Solidity types this client needs — `address`, `uintN`,
/// `bool` — each encoding to exactly one 32-byte ABI word.
///
/// - Note: Dynamic types (`string`, `bytes`, arrays, tuples) aren't
///   covered — ERC-20 `balanceOf` and Chainlink `latestRoundData()`, the
///   calls this client makes, only need static words.
public enum EthereumABIValue {
    case address(EthereumAddress)
    case uint256(BigUInt)
    case bool(Bool)

    var word: Data {
        switch self {
        case .address(let address):
            return Data(repeating: 0, count: 12) + address.rawBytes
        case .uint256(let value):
            // Precondition: value fits in 256 bits (32 bytes) — the
            // caller's responsibility, same as any other uint256 field.
            let bytes = value.serialize()
            return Data(repeating: 0, count: 32 - bytes.count) + bytes
        case .bool(let value):
            return Data(repeating: 0, count: 31) + Data([value ? 1 : 0])
        }
    }
}

/// Minimal Ethereum ABI encode/decode helpers — function-selector computation,
/// static-word call-data encoding, and static-word return-data decoding.
/// Backs `EthereumRPCClient`'s contract-call methods (`erc20Balance`,
/// `latestRoundData`) and is available directly for a caller's own contract
/// calls via `EthereumRPCClient.call(to:data:)`.
public enum EthereumABI {
    /// Computes the 4-byte function selector for `signature` (e.g.
    /// `"balanceOf(address)"`) — Keccak-256(signature)'s first 4 bytes.
    ///
    /// - Parameter signature: The canonical function signature — name plus
    ///   parenthesized, comma-separated parameter types, no parameter names or
    ///   spaces (e.g. `"transfer(address,uint256)"`).
    public static func selector(_ signature: String) -> Data {
        ethereumFunctionSelector(signature: signature)
    }

    /// Encodes a contract call's data: `selector` followed by each of
    /// `parameters`' 32-byte ABI words, in order.
    public static func encodeCall(
        selector: Data,
        parameters: [EthereumABIValue] = []
    ) -> Data {
        selector + parameters.map(\.word).reduce(Data(), +)
    }

    /// Splits ABI return data into 32-byte words.
    ///
    /// - Note: Indexes off `data.startIndex`/`data.endIndex`, not `0`/
    ///   `data.count` — a `Data` slice (e.g. from `dropFirst(_:)`) retains
    ///   its original, non-zero-based indices, so offsetting from `0`
    ///   directly would index out of bounds for anything but a freshly
    ///   constructed `Data`.
    public static func words(_ data: Data) -> [Data] {
        stride(from: data.startIndex, to: data.endIndex, by: 32).map {
            data[$0..<Swift.min(data.index($0, offsetBy: 32), data.endIndex)]
        }
    }

    /// Decodes a 32-byte word as an unsigned integer.
    public static func decodeUInt256(_ word: Data) -> BigUInt {
        BigUInt(word)
    }

    /// Decodes a 32-byte word as a two's-complement signed integer.
    public static func decodeInt256(_ word: Data) -> BigInt {
        let magnitude = BigUInt(word)

        guard let firstByte = word.first, firstByte & 0x80 != 0 else {
            return BigInt(magnitude)
        }

        return BigInt(magnitude) - (BigInt(1) << 256)
    }

    /// Decodes a 32-byte word as an address — its last 20 bytes.
    ///
    /// - Throws: ``WalletKitError/invalidAddress(reason:)`` if `word`'s
    ///   last 20 bytes aren't a valid address (can't happen for a
    ///   well-formed ABI word; `EthereumAddress(rawBytes:)` only rejects
    ///   the wrong byte count).
    public static func decodeAddress(_ word: Data) throws -> EthereumAddress {
        try EthereumAddress(rawBytes: word.suffix(20))
    }

    /// Decodes a 32-byte word as a boolean — non-zero is `true`.
    public static func decodeBool(_ word: Data) -> Bool {
        word.last != 0
    }
}
