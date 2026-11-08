// What the Sui staking tab and sheets derive from a stored position: the unstake action, the payout,
// the summary lines and the validator commission.

import Foundation
import Testing
import WalletKit
@testable import ReefrWallet

@Suite(.timeLimit(.minutes(1)))
struct SuiStakingModelTests {
    private func details(_ positions: [SuiStakePosition], epoch: UInt64 = 100) -> SuiStakingDetails {
        SuiStakingDetails(
            epoch: epoch,
            epochDurationMs: 86_400_000,
            epochStartTimestampMs: 1_800_000_000_000,
            pendingSubmissions: [],
            positions: positions
        )
    }

    // MARK: Unstake action

    @Test func anAmountBelowTheStakeIsPartialAndTheWholeStakeIsFull() {
        let stake = suiStakedSui(principal: 5_000_000_000)

        #expect(SuiStakingModel.unstakeAction(stake: stake, amount: nil) == nil)
        #expect(SuiStakingModel.unstakeAction(stake: nil, amount: 1) == nil)
        #expect(SuiStakingModel.unstakeAction(stake: stake, amount: 5_000_000_000) == .unstake(stake))
        #expect(
            SuiStakingModel.unstakeAction(stake: stake, amount: 2_000_000_000)
                == .unstakePartial(stake, amount: 2_000_000_000)
        )
    }

    @Test func anAmountAboveTheStakeIsRefusedRatherThanUnstakingEverything() {
        let stake = suiStakedSui(principal: 5_000_000_000)

        #expect(SuiStakingModel.unstakeAction(stake: stake, amount: 5_000_000_001) == nil)
    }

    @Test func onlyAStakeOfTwoSuiOrMoreCanBeSplit() {
        #expect(!SuiStakingModel.canSplit(suiStakedSui(principal: 1_999_999_999)))
        #expect(SuiStakingModel.canSplit(suiStakedSui(principal: 2_000_000_000)))
    }

    // MARK: Payout

    @Test func aPayoutIsThePrincipalPlusTheMatchingShareOfTheRewards() {
        let position = suiPosition(suiStakedSui(principal: 10_000_000_000), reward: 1_000_000_000)

        #expect(SuiStakingModel.estimatedPayout(position, amount: nil) == 11_000_000_000)
        #expect(SuiStakingModel.estimatedPayout(position, amount: 5_000_000_000) == 5_500_000_000)
        #expect(SuiStakingModel.estimatedPayout(position, amount: 0) == nil)
        #expect(SuiStakingModel.estimatedPayout(position, amount: 10_000_000_001) == nil)
    }

    @Test func aStakeNotYetEarningPaysOnlyItsPrincipalAndUnknownRewardsAreNotInvented() {
        let pending = suiPosition(status: .pending, reward: 5)
        let unknown = suiPosition(reward: nil)

        #expect(SuiStakingModel.estimatedPayout(pending, amount: nil) == pending.stake.principal)
        #expect(SuiStakingModel.estimatedPayout(unknown, amount: nil) == unknown.stake.principal)
    }

    // MARK: Summary

    @Test func theRewardsLineIsAnEstimateAndSaysWhenItIsPartial() {
        let known = suiPosition(reward: 1_000_000_000)
        let unknown = suiPosition(suiStakedSui(byte: 0xCC), reward: nil)

        func line(_ positions: [SuiStakePosition]) -> String? {
            SuiStakingModel.rewardsLine(details: details(positions), suiPrice: nil)
        }

        #expect(line([]) == nil)
        #expect(line([known])?.contains("at least") == false)
        #expect(line([known, unknown])?.contains("at least") == true)
        #expect(line([unknown]) == "Rewards unavailable")
    }

    @Test func theRewardsLineAddsTheDollarValueWhenThePriceIsKnown() throws {
        let line = try #require(SuiStakingModel.rewardsLine(details: details([suiPosition()]), suiPrice: 2))

        #expect(line.hasSuffix("US$)"))
    }

    @Test func theNextEpochIsCountedFromTheNodesTiming() throws {
        let stored = details([])
        let start = Date(timeIntervalSince1970: 1_800_000_000)

        func text(after seconds: TimeInterval) -> String? {
            SuiStakingModel.nextEpochText(details: stored, now: start.addingTimeInterval(seconds))
        }

        #expect(text(after: 3_600)?.contains("23") == true)
        #expect(text(after: 90_000) == "Epoch ending soon")

        var unknown = stored
        unknown.epochDurationMs = 0
        #expect(SuiStakingModel.nextEpochText(details: unknown, now: start) == nil)
    }

    // MARK: Validators

    @Test func commissionIsShownAsAPercentage() {
        let pool = SuiStakingPool(
            id: "p", activationEpoch: 1, deactivationEpoch: nil, rewardsPool: 0, suiBalance: 0,
            exchangeRatesTableId: "t"
        )

        func commission(_ points: UInt64) -> String {
            SuiValidatorPicker.commissionText(
                SuiValidator(address: "a", name: "n", commissionBasisPoints: points, votingPower: 1, pool: pool)
            )
        }

        #expect(commission(500).contains("5"))
        #expect(commission(0).contains("0"))
        #expect(commission(250).contains("2"))
    }
}
