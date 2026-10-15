// Unit tests for TransactionSyncService.balanceRefreshTokens — which
// balances a batch of newly synced transactions refreshes.

import Testing
import WalletKit
@testable import ReefrWallet

struct BalanceRefreshSelectionTests {
    private let usdt = "TR7NHqjeKQxGTCi8q8ZY4pL8otSzgjLj6t"

    @Test func nothingNewRefreshesNothing() {
        #expect(TransactionSyncService.balanceRefreshTokens(for: []).isEmpty)
    }

    /// A Tron stake (`FreezeBalanceV2Contract`) syncs with no effects, but
    /// moves TRX out of the spendable balance.
    @Test func aTransactionWithoutEffectsRefreshesTheNativeBalance() {
        let stake = BlockchainTransaction(identifier: "stake", status: .confirmed, effects: [])

        #expect(TransactionSyncService.balanceRefreshTokens(for: [stake]) == [nil])
    }

    /// The token moved, and the sender paid the fee in the native asset.
    @Test func aTokenTransferRefreshesTheTokenAndTheNativeBalance() {
        let transfer = BlockchainTransaction(
            identifier: "trc20",
            status: .confirmed,
            effects: [BlockchainTransactionEffect(index: 0, kind: .tokenTransfer, assetIdentifier: usdt, amount: "1")]
        )

        #expect(TransactionSyncService.balanceRefreshTokens(for: [transfer]) == [nil, usdt])
    }

    @Test func approvalsAndUnknownEffectsStillRefreshTheNativeBalance() {
        let approval = BlockchainTransaction(
            identifier: "approve",
            status: .confirmed,
            effects: [
                BlockchainTransactionEffect(index: 0, kind: .tokenApproval, assetIdentifier: usdt),
                BlockchainTransactionEffect(index: 1, kind: .unknown)
            ]
        )

        #expect(TransactionSyncService.balanceRefreshTokens(for: [approval]) == [nil])
    }
}
