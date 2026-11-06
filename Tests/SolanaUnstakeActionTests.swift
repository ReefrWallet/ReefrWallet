// Tests of the action the Unstake sheet's inputs describe: an amount that isn't valid must never
// become a full unstake.

import Foundation
import Testing
import WalletKit
@testable import ReefrWallet

@Suite(.timeLimit(.minutes(1)))
struct SolanaUnstakeActionTests {
    private func position(
        _ address: String = "a",
        withdrawer: String = solanaOwner
    ) -> SolanaStakePosition {
        SolanaStakePosition(
            account: stakeAccount(address, stake: 5_000_000_000, withdrawer: withdrawer),
            activation: .init(),
            status: .active
        )
    }

    private func action(_ selected: [SolanaStakePosition], amount: UInt64?) -> SolanaStakingAction? {
        SolanaStakingModel.unstakeAction(selected: selected, owner: solanaOwner, amount: amount)
    }

    @Test func anAccountThisWalletCanSplitGoesByItsAmount() {
        #expect(action([position()], amount: nil) == nil)
        #expect(action([position()], amount: 1_000_000_000) == .unstakePartial(account: "a", lamports: 1_000_000_000))
        #expect(action([position()], amount: 5_000_000_000) == .unstake(accounts: ["a"]))
    }

    @Test func tooLargeAnAmountIsRefusedRatherThanUnstakingEverything() throws {
        let tooLarge = try #require(action([position()], amount: 5_000_000_001))
        let clock = SolanaClock(epoch: 100, epochStartTimestamp: 0, slot: 0, unixTimestamp: 1_000)

        #expect(tooLarge == .unstakePartial(account: "a", lamports: 5_000_000_001))

        #expect(throws: SolanaStakingError.amountTooLarge) {
            try SolanaStakingService.validate(
                tooLarge,
                owner: solanaOwner,
                positions: [position()],
                clock: clock,
                balance: 100_000_000_000,
                minimum: 1_000_000_000,
                rent: 2_282_880
            )
        }
    }

    @Test func wholeAccountsIgnoreTheAmount() {
        #expect(action([position(withdrawer: solanaOtherWallet)], amount: nil) == .unstake(accounts: ["a"]))
        #expect(action([position("b"), position("a")], amount: nil) == .unstake(accounts: ["a", "b"]))
        #expect(action([], amount: 1) == nil)
    }
}
