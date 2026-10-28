//
//  TronTransactionParametersView.swift
//  Reefr Wallet
//
//  Created by Andrey Yurkevich on 13.10.26.
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import SwiftUI
import WalletKit

/// A dapp-supplied Tron transaction decoded from the exact bytes that get
/// signed, decoding TRC-20 `transfer`/`approve`/`transferFrom` calls and
/// Stake 2.0 stake/unstake/withdraw. Fees are shown by ``TransactionFeesView``.
struct TronTransactionParametersView: View {
    let account: Account
    let preview: TronTransactionPreview
    let site: String

    var body: some View {
        ParameterSection {
            ParameterRow(String(localized: .commonSite), value: site)
        }

        ParameterSection(String(localized: .commonTransaction)) {
            FromRow(account: account)

            ForEach(rows, id: \.label) { row in
                if row.isCallData {
                    ParameterRow(row.label) {
                        ScrollingMonoText(row.value, maxLines: 4)
                    }
                } else {
                    ParameterRow(row.label, value: row.value, lineLimit: nil)
                }
            }
        }

        ParameterBlock(String(localized: .commonRawBytes), text: preview.transaction.rawBytes.hexEncoded, maxLines: 6)
    }
}

// MARK: - Rows

extension TronTransactionParametersView {
    struct Row {
        var isCallData = false
        let label: String
        let value: String
    }

    var rows: [Row] {
        let transaction = preview.transaction
        var rows: [Row]

        switch transaction.contract {
        case let .transfer(_, to, amount):
            rows = [
                Row(label: String(localized: .commonAction), value: "Send TRX"),
                Row(label: String(localized: .commonTo), value: to.string),
                Row(label: String(localized: .commonAmount), value: Self.trx(amount))
            ]
        case let .triggerSmartContract(_, contract, callValue, data):
            rows = [Row(label: String(localized: .tronTransactionParametersContract), value: contract.string)]
            rows += Self.callRows(data, token: preview.token)

            if callValue > 0 {
                rows.append(
                    Row(label: String(localized: .tronTransactionParametersTrxSent), value: Self.trx(callValue))
                )
            }

        case let .freezeBalanceV2(_, amount, resource):
            rows = [
                Row(label: String(localized: .commonAction), value: "Stake TRX"),
                Row(label: String(localized: .commonAmount), value: Self.trx(amount)),
                Row(label: String(localized: .tronTransactionParametersResource), value: Self.resourceName(resource))
            ]
        case let .unfreezeBalanceV2(_, amount, resource):
            rows = [
                Row(label: String(localized: .commonAction), value: "Unstake TRX"),
                Row(label: String(localized: .commonAmount), value: Self.trx(amount)),
                Row(label: String(localized: .tronTransactionParametersResource), value: Self.resourceName(resource))
            ]
        case .withdrawExpireUnfreeze:
            rows = [Row(label: String(localized: .commonAction), value: "Withdraw unstaked TRX")]
        }

        if let memo = transaction.memo, !memo.isEmpty {
            rows.append(
                Row(
                    label: String(localized: .commonMemo),
                    value: String(data: memo, encoding: .utf8) ?? memo.hexEncoded
                )
            )
        }

        let expiration = Date(timeIntervalSince1970: TimeInterval(transaction.expiration) / 1000)
        rows.append(
            Row(
                label: String(localized: .commonExpires),
                value: expiration.formatted(date: .abbreviated, time: .standard)
            )
        )

        return rows
    }

    static func trx(_ sun: UInt64) -> String {
        let value = Decimal(sun) / Decimal(1_000_000)
        return value.formatted(symbol: "TRX")
    }

    static func resourceName(_ resource: TronRawTransaction.Resource) -> String {
        switch resource {
        case .bandwidth: String(localized: .tronTransactionParametersBandwidth)
        case .energy: String(localized: .tronTransactionParametersEnergy)
        case .tronPower: String(localized: .tronTransactionParametersTronPower)
        }
    }

    /// Decodes the common TRC-20 calls; anything else shows its selector
    /// and calldata.
    static func callRows(_ data: Data, token: TronTransactionPreview.Token?) -> [Row] {
        let selector = data.prefix(4).hexEncoded
        let words = argumentWords(data)

        switch (selector, words.count) {
        case ("0xa9059cbb", 2):
            return [Row(label: String(localized: .commonAction), value: "Token transfer")]
                + [
                    Row(label: String(localized: .commonTo), value: address(words[0])),
                    Row(label: String(localized: .commonAmount), value: amount(words[1], token))
                ]
        case ("0x095ea7b3", 2):
            return [Row(label: String(localized: .commonAction), value: "Token approval")]
                + [Row(label: String(localized: .tronTransactionParametersSpender), value: address(words[0]))]
                + [Row(label: String(localized: .tronTransactionParametersAllowance), value: amount(words[1], token))]
        case ("0x23b872dd", 3):
            return [Row(label: String(localized: .commonAction), value: "Token transfer from")]
                + [
                    Row(label: String(localized: .commonFrom), value: address(words[0])),
                    Row(label: String(localized: .commonTo), value: address(words[1]))
                ]
                + [Row(label: String(localized: .commonAmount), value: amount(words[2], token))]
        default:
            let function = Row(
                label: String(localized: .commonFunction),
                value: data.isEmpty ? String(localized: .commonNone) : selector
            )

            let callData = Row(
                isCallData: true,
                label: String(localized: .tronTransactionParametersCallData),
                value: data.hexEncoded
            )

            return data.count > 4 ? [function, callData] : [function]
        }
    }

    /// The call's arguments as 32-byte ABI words.
    ///
    /// A trailing word the calldata truncates is right-padded with zeros,
    /// because that is what the TVM reads: calldata shorter than the offset a
    /// parameter sits at reads as zeros, so a 37-byte `transfer` call executes
    /// with an amount of `data[36] << 248`. Slicing short instead would have
    /// shown that same byte as a tiny amount — an approval sheet disagreeing
    /// with the transaction being signed.
    static func argumentWords(_ data: Data) -> [Data] {
        stride(from: 4, to: data.count, by: 32).map { offset in
            let start = data.startIndex + offset
            let word = Data(data[start..<min(start + 32, data.endIndex)])
            return word + Data(repeating: 0, count: 32 - word.count)
        }
    }

    static func address(_ word: Data) -> String {
        guard word.count == 32, word.prefix(12).allSatisfy({ $0 == 0 }) else {
            return word.hexEncoded
        }

        return (try? TronAddress(rawBytes: Data([0x41]) + word.suffix(20)).string) ?? word.hexEncoded
    }

    /// `"20.0 USDT"`, `"Unlimited USDT"`, or raw base units when the
    /// token's decimals are unknown.
    static func amount(_ word: Data, _ token: TronTransactionPreview.Token?) -> String {
        let value = BigUInt(word)
        let symbol = token.map { " \($0.symbol)" } ?? ""

        if value == BigUInt(2).power(256) - 1 {
            return String(localized: .tronTransactionParametersUnlimited(symbol))
        }

        guard let token else {
            return String(localized: .tronTransactionParametersBaseUnits(String(value)))
        }

        return "\(tokenAmount(value, decimals: Int(token.decimals)))\(symbol)"
    }

    static func tokenAmount(_ value: BigUInt, decimals: Int) -> String {
        guard decimals > 0 else {
            return "\(value)"
        }

        let digits = String(value).leftPadded(to: decimals + 1)
        let whole = digits.dropLast(decimals)
        var fraction = String(digits.suffix(decimals))
        while fraction.count > 1, fraction.hasSuffix("0") {
            fraction.removeLast()
        }

        return "\(whole).\(fraction)"
    }
}

private extension String {
    func leftPadded(to length: Int) -> String {
        count >= length ? self : String(repeating: "0", count: length - count) + self
    }
}
