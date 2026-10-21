// Unit tests for TronTransactionParametersView's calldata decoding — the
// approval sheet's TRC-20 rows. The sheet is the only place the user sees
// what they're signing, so a decode that disagrees with the TVM is a
// spoofing vector, not a cosmetic bug.

import Foundation
import Testing
import WalletKit
@testable import ReefrWallet

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
