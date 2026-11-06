// Unit tests for TronTransactionParametersView's calldata decoding — the
// approval sheet's TRC-20 rows. The sheet is the only place the user sees
// what they're signing, so a decode that disagrees with the TVM is a
// spoofing vector, not a cosmetic bug.

import Foundation
import SwiftData
import Testing
import WalletKit
@testable import ReefrWallet

// TronWeb 6.5.1 `raw_data_hex` vectors, as in WalletKit's `TronRawTransactionTests`.
private let voteHex =
    "0a02e94222086394747da9fee42140c08afee680335a870108041282010a30747970652e676f6f676c65617069732e63"
    + "6f6d2f70726f746f636f6c2e566f74655769746e657373436f6e7472616374124e0a15417e5f4552091a69125d5dfcb7"
    + "b8c2659029395bdf121a0a1541a614f803b6fd780986a42c78ec9c7f77e6ded13c10fa0112190a15418440ffd578f7a5"
    + "abf3537b5f46a6980d382db581107870e0b5fae68033"
private let withdrawBalanceHex =
    "0a02e94222086394747da9fee42140c08afee680335a53080d124f0a34747970652e676f6f676c65617069732e636f6d"
    + "2f70726f746f636f6c2e576974686472617742616c616e6365436f6e747261637412170a15417e5f4552091a69125d5d"
    + "fcb7b8c2659029395bdf70e0b5fae68033"
private let cancelAllUnfreezeHex =
    "0a02e94222086394747da9fee42140c08afee680335a57083b12530a38747970652e676f6f676c65617069732e636f6d"
    + "2f70726f746f636f6c2e43616e63656c416c6c556e667265657a655632436f6e747261637412170a15417e5f4552091a"
    + "69125d5dfcb7b8c2659029395bdf70e0b5fae68033"

/// WalletKit's `Data(hexString:)` is internal.
private func hexData(_ hex: String) -> Data {
    Data(stride(from: 0, to: hex.count, by: 2).map { offset in
        let start = hex.index(hex.startIndex, offsetBy: offset)
        return UInt8(hex[start..<hex.index(start, offsetBy: 2)], radix: 16) ?? 0
    })
}

private let transferSelector = Data([0xa9, 0x05, 0x9c, 0xbb])
private let recipientWord = Data(repeating: 0, count: 12) + Data(repeating: 0x11, count: 20)
private let usdt = TronTransactionPreview.Token(decimals: 6, symbol: "USDT")

private func amountRow(_ data: Data, token: TronTransactionPreview.Token? = usdt) -> String? {
    TronTransactionParametersView
        .callRows(data, token: token)
        .first { $0.label == "Amount" }?
        .value
}

@Suite(.timeLimit(.minutes(1)))
struct TronTransactionParametersRowsTests {
    @Test
    func decodesAWellFormedTransfer() throws {
        let amount = Data(repeating: 0, count: 29) + Data([0x01, 0x31, 0x2d]) // 78_125 base units
        #expect(amountRow(transferSelector + recipientWord + amount) == "0.078125 USDT")
    }

    /// Calldata shorter than a parameter's 32-byte slot reads as zeros in the
    /// TVM, so a one-byte amount executes as `byte << 248`. Slicing the word
    /// short instead showed that byte as a tiny amount.
    @Test
    func rightPadsATruncatedAmountWordLikeTheTVM() throws {
        let truncated = transferSelector + recipientWord + Data([0x01])
        let padded = transferSelector + recipientWord + Data([0x01]) + Data(repeating: 0, count: 31)
        let one = transferSelector + recipientWord + Data(repeating: 0, count: 31) + Data([0x01])

        #expect(amountRow(truncated) == amountRow(padded))
        #expect(amountRow(truncated) != amountRow(one))
    }

    @Test
    func showsBaseUnitsWhenTheTokenIsUnknown() throws {
        let amount = Data(repeating: 0, count: 31) + Data([0x07])
        #expect(amountRow(transferSelector + recipientWord + amount, token: nil) == "7 (base units)")
    }

    @Test
    func listsEachVoteOfAVoteRequest() throws {
        let rows = try Self.rows(voteHex)

        #expect(rows.first { $0.label == "Action" }?.value == "Vote")
        #expect(rows.first { $0.label == "TR7NHqjeKQxGTCi8q8ZY4pL8otSzgjLj6t" }?.value == "250 votes")
        #expect(rows.filter { $0.value.hasSuffix("votes") }.map(\.value) == ["250 votes", "120 votes"])
    }

    @Test
    func namesRewardClaimsAndUnstakeCancellations() throws {
        #expect(try Self.rows(withdrawBalanceHex).first?.value == "Claim voting rewards")
        #expect(try Self.rows(cancelAllUnfreezeHex).first?.value == "Cancel unstaking")
    }

    private static func rows(_ hex: String) throws -> [TronTransactionParametersView.Row] {
        let transaction = try TronRawTransaction(rawBytes: hexData(hex))
        let keyStoreId = KeyStoreModel(
            .watchOnly,
            deviceId: nil,
            name: "t",
            mnemonicEntropy: nil,
            mnemonicWordlist: nil,
            transport: nil,
            vendor: nil
        ).persistentModelID

        let account = ReefrWallet.Account(
            address: transaction.contract.owner.string,
            blockchain: .tron(.mainnet),
            derivationPath: nil,
            keyStoreId: keyStoreId,
            name: "Tron #1"
        )

        return TronTransactionParametersView(
            account: account,
            preview: TronTransactionPreview(transaction: transaction),
            site: "https://example.com"
        ).rows
    }

    @Test
    func reportsAnUnlimitedAllowance() throws {
        let approveSelector = Data([0x09, 0x5e, 0xa7, 0xb3])
        let maxWord = Data(repeating: 0xff, count: 32)

        let allowance = TronTransactionParametersView
            .callRows(approveSelector + recipientWord + maxWord, token: usdt)
            .first { $0.label == "Allowance" }?
            .value

        #expect(allowance == "Unlimited USDT")
    }
}
