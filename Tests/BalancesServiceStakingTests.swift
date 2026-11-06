// Tests that balance updates keep the stored staking position current, and that the
// two succeed or fail independently. The Tron endpoint is unreachable, so every
// balance request fails; the position is read through a recording refresher.

import Foundation
import Testing
import WalletKit
@testable import ReefrWallet

@Suite(.timeLimit(.minutes(2)))
struct BalancesServiceStakingTests {
    private let unreachable = URL(string: "http://127.0.0.1:9")

    private struct Fixture {
        let account: ReefrWallet.Account
        let refresher: RecordingStakingRefresher
        let service: BalancesService
    }

    private func makeFixture(
        failingRefresher: Bool = false,
        blockchain: Blockchain = .tron(.testnet)
    ) async throws -> Fixture {
        let databaseService = try makeDatabaseService()
        let refresher = RecordingStakingRefresher(failing: failingRefresher)
        let account = try await makeStakingAccount(databaseService, blockchain: blockchain, rpcURL: unreachable)

        return Fixture(
            account: account,
            refresher: refresher,
            service: BalancesService(databaseService: databaseService, stakingRefresher: refresher)
        )
    }

    @Test func readsThePositionEvenWhenBalancesFail() async throws {
        let fixture = try await makeFixture()

        await #expect(throws: (any Error).self) {
            try await fixture.service.updateBalances(fixture.account)
        }

        #expect(await fixture.refresher.accounts == [fixture.account.address])
    }

    @Test func aFailedPositionReadNeverReplacesTheBalanceError() async throws {
        let fixture = try await makeFixture(failingRefresher: true)

        do {
            try await fixture.service.updateBalances(fixture.account)
            Issue.record("Expected the balance update to fail.")
        } catch {
            #expect(!(error is RecordingStakingRefresher.Failure))
        }

        #expect(await fixture.refresher.accounts.count == 1)
    }

    @Test func canSkipThePosition() async throws {
        let fixture = try await makeFixture()

        _ = try? await fixture.service.updateBalances(fixture.account, includeStaking: false)

        #expect(await fixture.refresher.accounts.isEmpty)
    }

    @Test func leavesChainsWithoutStakingAlone() async throws {
        let fixture = try await makeFixture(blockchain: .evm(.custom(31_337)))

        _ = try? await fixture.service.updateBalances(fixture.account)

        #expect(await fixture.refresher.accounts.isEmpty)
    }

    /// Tron has no all-balances call, so transaction sync queues per-token updates that bypass
    /// `updateBalances`; the queue still reads the position, once per account and despite failures.
    @Test func readsThePositionOncePerAccountWhenTheQueueDrains() async throws {
        let fixture = try await makeFixture()

        let account = fixture.account

        for tokenAddress in ["TXYZopYRdj2D9XRtbG411XZZ3kM5VkAeBf", "TF17BgPaZYbz8oxbjhriubPDsA7ArKoLX3", nil] {
            await fixture.service.enqueueBalanceUpdate(
                account: account,
                tokenAddress: tokenAddress,
                blockchain: account.blockchain
            )
        }

        var reads = 0

        for _ in 0..<600 where reads == 0 {
            try await Task.sleep(for: .milliseconds(10))
            reads = await fixture.refresher.accounts.count
        }

        try await Task.sleep(for: .milliseconds(300))

        #expect(await fixture.refresher.accounts == [fixture.account.address])
    }
}
