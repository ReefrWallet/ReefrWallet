//
//  EthereumTransactionRequest.swift
//  Reefr Wallet
//
//  Created by Andrey Yurkevich on 07.10.26.
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import WalletKit

/// A strictly parsed `eth_sendTransaction` transaction object. An absent
/// (or `null`) field takes its default; a present but malformed one is
/// rejected with `invalidParams` rather than silently defaulted.
struct EthereumTransactionRequest: Sendable {
    /// Below this no transaction can execute.
    static let minimumGasLimit = BigUInt(21_000)

    let data: Data
    let from: String
    let gasLimit: BigUInt?
    let gasPrice: BigUInt?
    let maxFeePerGas: BigUInt?
    let maxPriorityFeePerGas: BigUInt?
    let to: EthereumAddress?
    let toString: String?
    let value: BigUInt

    /// Whether the dapp supplied any gas/fee field.
    var hasFeeOverrides: Bool {
        gasLimit != nil || gasPrice != nil || maxFeePerGas != nil || maxPriorityFeePerGas != nil
    }

    init(_ json: JSONValue) throws(DappError) {
        guard let tx = json.objectValue else {
            throw .invalidParams("eth_sendTransaction expects [tx] with a from address")
        }

        guard let from = tx["from"]?.stringValue else {
            throw .invalidParams("eth_sendTransaction expects [tx] with a from address")
        }

        self.from = from

        if let toString = try Self.string(tx, "to") {
            guard let parsed = try? EthereumAddress(string: toString) else {
                throw .invalidParams("to: invalid address")
            }

            to = parsed
            self.toString = toString
        } else {
            to = nil
            toString = nil
        }

        value = try Self.quantity(tx, "value") ?? 0

        // `input` is the spec name; most dapps send `data`.
        let data = try Self.bytes(tx, "data")
        let input = try Self.bytes(tx, "input")
        if let data, let input, data != input {
            throw .invalidParams("data and input differ")
        }

        self.data = data ?? input ?? Data()

        gasLimit = try Self.quantity(tx, "gas")
        gasPrice = try Self.quantity(tx, "gasPrice")
        maxFeePerGas = try Self.quantity(tx, "maxFeePerGas")
        maxPriorityFeePerGas = try Self.quantity(tx, "maxPriorityFeePerGas")

        if let gasLimit, gasLimit < Self.minimumGasLimit {
            throw .invalidParams("gas: below \(Self.minimumGasLimit)")
        }

        if gasPrice != nil, maxFeePerGas != nil || maxPriorityFeePerGas != nil {
            throw .invalidParams("gasPrice cannot be combined with maxFeePerGas/maxPriorityFeePerGas")
        }

        if let maxFeePerGas, let maxPriorityFeePerGas, maxPriorityFeePerGas > maxFeePerGas {
            throw .invalidParams("maxPriorityFeePerGas exceeds maxFeePerGas")
        }
    }
}

// MARK: - Fees

extension EthereumTransactionRequest {
    /// Merges the dapp's fee fields over the network's rates. A legacy
    /// `gasPrice` caps both fields, as EIP-1559 wallets conventionally do;
    /// a lone cap pulls the estimated other one into a valid range.
    func feeCaps(rates: EthereumFeeRates) -> (maxFee: BigUInt, maxPriorityFee: BigUInt) {
        if let gasPrice {
            return (gasPrice, gasPrice)
        }

        switch (maxFeePerGas, maxPriorityFeePerGas) {
        case let (maxFee?, maxPriorityFee?):
            return (maxFee, maxPriorityFee)
        case let (maxFee?, nil):
            return (maxFee, min(rates.maxPriorityFeePerGas, maxFee))
        case let (nil, maxPriorityFee?):
            return (max(rates.maxFeePerGas, maxPriorityFee), maxPriorityFee)
        case (nil, nil):
            return (rates.maxFeePerGas, rates.maxPriorityFeePerGas)
        }
    }
}

// MARK: - Field parsing

private extension EthereumTransactionRequest {
    static let hexCharacters = Set("0123456789abcdefABCDEF")

    /// `0x`-prefixed, even-length hex bytes; `0x` alone is empty data.
    static func bytes(_ tx: [String: JSONValue], _ key: String) throws(DappError) -> Data? {
        guard let digits = try hexDigits(tx, key, kind: "hex bytes") else {
            return nil
        }

        guard digits.count.isMultiple(of: 2), let data = decodeHexData(String(digits)) else {
            throw .invalidParams("\(key): expected hex bytes")
        }

        return data
    }

    /// The digits after `0x`, or `nil` when `key` is absent/`null`.
    static func hexDigits(_ tx: [String: JSONValue], _ key: String, kind: String) throws(DappError) -> Substring? {
        guard let string = try string(tx, key) else {
            return nil
        }

        guard string.hasPrefix("0x") || string.hasPrefix("0X") else {
            throw .invalidParams("\(key): expected \(kind)")
        }

        let digits = string.dropFirst(2)
        guard digits.allSatisfy(hexCharacters.contains) else {
            throw .invalidParams("\(key): expected \(kind)")
        }

        return digits
    }

    /// A `0x`-prefixed uint256 hex quantity.
    static func quantity(_ tx: [String: JSONValue], _ key: String) throws(DappError) -> BigUInt? {
        guard let digits = try hexDigits(tx, key, kind: "hex quantity") else {
            return nil
        }

        guard !digits.isEmpty, digits.count <= 64, let value = BigUInt(String(digits), radix: 16) else {
            throw .invalidParams("\(key): expected hex quantity")
        }

        return value
    }

    /// A string field, `nil` when absent/`null`, rejected when any other type.
    static func string(_ tx: [String: JSONValue], _ key: String) throws(DappError) -> String? {
        switch tx[key] {
        case nil, .some(.null):
            return nil
        case let .some(.string(value)):
            return value
        default:
            throw .invalidParams("\(key): expected a string")
        }
    }
}
