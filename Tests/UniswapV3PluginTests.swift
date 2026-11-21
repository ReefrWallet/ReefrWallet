// Uniswap V3 plugin outcomes against a fake chain: ownership at the pinned
// block, withdrawn positions, fee labelling, history checkpoints, reorgs and
// the shared history budget (ADR-073).

import BigInt
import Foundation
import Testing
import WalletKit
@testable import ReefrWallet

@Suite(.timeLimit(.minutes(1)))
struct UniswapV3PluginTests {
    private static let owner = "0x" + String(repeating: "aa", count: 20)
    private static let other = "0x" + String(repeating: "bb", count: 20)
    private static let q128 = BigUInt(1) << 128

    // MARK: - Fixture

    private struct Fixture {
        let account: ReefrWallet.Account
        let chain = FakeUniswapV3Chain()
        let plugin: UniswapV3Plugin

        init(account: ReefrWallet.Account, tokenSource: FakeUniswapV3TokenSource = .init()) {
            self.account = account
            let chain = chain
            plugin = UniswapV3Plugin(
                deployments: [1: FakeUniswapV3Chain.deployment],
                readerFactory: { _ in chain },
                tokenSource: tokenSource
            )
        }

        /// An owned, in-range position with liquidity.
        func addPosition(_ tokenId: BigUInt, liquidity: BigUInt = 1_000_000_000_000, mintBlock: UInt64? = 100) {
            chain.setOwner(tokenId, .owner(UniswapV3PluginTests.owner))
            chain.setPosition(tokenId, .init(liquidity: liquidity))

            if let mintBlock {
                chain.addMint(tokenId, to: UniswapV3PluginTests.owner, block: mintBlock)
            }
        }

        func fetch(
            _ tokenIds: [BigUInt],
            previous: [DefiPosition] = [],
            mints: [BigUInt: DefiMintEvidence] = [:],
            budget: Int = 20,
            rotation: Int = 0
        ) async throws -> [DefiPositionOutcome] {
            let manager = FakeUniswapV3Chain.deployment.positionManager.string.lowercased()
            let nfts = tokenIds.map { id in
                NFT(
                    collectionName: nil,
                    id: "nft|\(id)",
                    imageURL: nil,
                    isTransferable: true,
                    metadataURI: nil,
                    name: nil,
                    objectType: nil,
                    quantity: 1,
                    reference: NFTReference(
                        collection: manager,
                        isTransferable: true,
                        standard: .erc721,
                        tokenId: String(id)
                    ),
                    sendState: nil
                )
            }

            let input = DefiInput(
                accountKey: "account",
                mints: Dictionary(uniqueKeysWithValues: mints.map { ("nft|\($0.key)", $0.value) }),
                nfts: nfts,
                positions: previous,
                revision: "r",
                scanStates: [:]
            )

            return try await plugin.fetch(
                DefiPluginContext(account: account, budget: DefiRequestBudget(budget), input: input, rotation: rotation)
            )
        }
    }

    private func makeFixture(tokenSource: FakeUniswapV3TokenSource = .init()) async throws -> Fixture {
        let databaseService = try makeDatabaseService()
        let account = try await makeStakingAccount(
            databaseService,
            blockchain: .evm(.ethereum(.mainnet)),
            address: Self.owner
        )

        return Fixture(account: account, tokenSource: tokenSource)
    }

    private func record(
        _ outcomes: [DefiPositionOutcome],
        _ tokenId: BigUInt
    ) throws -> (DefiPositionRecord, UniswapV3Position) {
        let record = try #require(outcomes.compactMap { outcome -> DefiPositionRecord? in
            if case let .updated(record) = outcome, record.key == "1:\(tokenId)" {
                return record
            }

            return nil
        }.first)

        return (record, try record.payload.decoded())
    }

    private func previous(_ outcomes: [DefiPositionOutcome]) -> [DefiPosition] {
        outcomes.compactMap { outcome in
            guard case let .updated(record) = outcome else {
                return nil
            }

            return DefiPosition(
                id: record.key,
                isUSDValueComplete: record.isUSDValueComplete,
                key: record.key,
                kind: .uniswapV3,
                payload: record.payload,
                updatedAt: .now,
                usdValue: record.usdValue
            )
        }
    }

    // MARK: - Fees and withdrawals

    @Test func fullDecreaseBeforeCollectStaysVisibleAsWithdrawnWithoutInventedFees() async throws {
        let fixture = try await makeFixture()
        fixture.addPosition(1, liquidity: 0)
        fixture.chain.setPosition(1, .init(liquidity: 0, tokensOwed: (BigUInt(10).power(18), 2_000_000_000)))
        fixture.chain.addDecrease(1, BigUInt(10).power(18), 2_000_000_000, block: 200)

        let (record, position) = try record(try await fixture.fetch([1]), 1)

        #expect(position.status == .withdrawn)
        #expect(position.fees.isZero)
        #expect(!position.isFeesExact)
        #expect(position.lifetimeFees == .zero)
        #expect(position.historyState == .complete)
        #expect(record.usdValue == 4_000)
        #expect(record.isUSDValueComplete)
    }

    @Test func mixedOwedPrincipalAndFeesNeverCountsAsFees() async throws {
        let fixture = try await makeFixture()
        fixture.addPosition(1)
        fixture.chain.setPosition(1, .init(
            feeGrowthInsideLast: .init(token0: 0, token1: 0),
            liquidity: 1_000,
            tokensOwed: (150, 150)
        ))
        fixture.chain.feeGrowthGlobal = .init(token0: Self.q128 * 2, token1: Self.q128 * 3)
        fixture.chain.addDecrease(1, 100, 100, block: 200)
        fixture.chain.addCollect(1, 100, 100, block: 300)

        let (_, position) = try record(try await fixture.fetch([1]), 1)

        #expect(position.pendingFees == .init(2_000, 3_000))
        #expect(position.fees == position.pendingFees)
        #expect(!position.isFeesExact)
        #expect(position.tokensOwed == .init(150, 150))
        // collected + claimable − decreased: 100 + 2_150 − 100.
        #expect(position.lifetimeFees == .init(2_150, 3_150))
    }

    @Test func owedAmountsAreFeesWhenNothingWasEverWithdrawn() async throws {
        let fixture = try await makeFixture()
        fixture.addPosition(1)
        fixture.chain.setPosition(1, .init(liquidity: 1_000, tokensOwed: (7, 9)))

        let (_, position) = try record(try await fixture.fetch([1]), 1)

        #expect(position.isFeesExact)
        #expect(position.fees == .init(7, 9))
    }

    @Test func emptyPositionIsRemoved() async throws {
        let fixture = try await makeFixture()
        fixture.addPosition(1, liquidity: 0)

        #expect(try await fixture.fetch([1]).contains(.removed(key: "1:1")))
    }

    // MARK: - Ownership

    @Test func chainAheadOfLedgerRemovesATransferredPosition() async throws {
        let fixture = try await makeFixture()
        fixture.addPosition(1)
        fixture.chain.setOwner(1, .owner(Self.other))

        #expect(try await fixture.fetch([1]) == [.removed(key: "1:1")])
    }

    @Test func onlyTheNonexistentTokenRevertProvesABurn() async throws {
        let fixture = try await makeFixture()
        fixture.addPosition(1)
        fixture.addPosition(2)
        fixture.addPosition(3)
        fixture.chain.setOwner(1, .revert(FakeUniswapV3Chain.errorRevert(UniswapV3Plugin.nonexistentTokenReason)))
        fixture.chain.setOwner(2, .revert(Data()))
        fixture.chain.setOwner(3, .revert(FakeUniswapV3Chain.errorRevert("something else")))

        let outcomes = try await fixture.fetch([1, 2, 3])

        #expect(outcomes.contains(.removed(key: "1:1")))
        #expect(outcomes.contains(.failed(key: "1:2")))
        #expect(outcomes.contains(.failed(key: "1:3")))
    }

    @Test func positionGoneFromNFTInputIsRemoved() async throws {
        let fixture = try await makeFixture()
        fixture.addPosition(1)
        fixture.addPosition(2)
        let first = try await fixture.fetch([1, 2])

        let second = try await fixture.fetch([1], previous: previous(first))

        #expect(second.contains(.removed(key: "1:2")))
        #expect(second.contains { $0.key == "1:1" && $0 != .removed(key: "1:1") })
    }

    // MARK: - History

    @Test func transferredInPositionFindsItsMintOnChain() async throws {
        let fixture = try await makeFixture()
        fixture.addPosition(1, mintBlock: 500)

        let (_, position) = try record(try await fixture.fetch([1]), 1)

        #expect(position.history.mint?.number == 500)
        #expect(position.createdAt == Date(timeIntervalSince1970: 500 * 12))
        #expect(position.historyState == .complete)
    }

    @Test func pendingMintSearchKeepsTheRowVisibleWithoutAPR() async throws {
        let fixture = try await makeFixture()
        fixture.addPosition(1, mintBlock: 500)

        // No budget: the row is still published from position state.
        let (record, position) = try record(try await fixture.fetch([1], budget: 0), 1)

        #expect(position.historyState == .loading)
        #expect(position.apr == nil)
        #expect(position.createdAt == nil)
        #expect(record.usdValue != nil)
    }

    @Test func mintAboveTheSafeBlockIsNotPersistedAndFollowsAReorg() async throws {
        let fixture = try await makeFixture()
        // Safe block is head − 10 = 990.
        fixture.addPosition(1, mintBlock: 995)

        let first = try await fixture.fetch([1])
        let (_, before) = try record(first, 1)
        #expect(before.history.mint == nil)
        #expect(before.createdAt == Date(timeIntervalSince1970: 995 * 12))

        fixture.chain.reorg(from: 992, salt: "f")
        fixture.chain.addMint(1, to: Self.owner, block: 997)

        let (_, after) = try record(try await fixture.fetch([1], previous: previous(first)), 1)
        #expect(after.createdAt == Date(timeIntervalSince1970: 997 * 12))
    }

    @Test func persistedMintWhoseBlockReorganizedIsRediscovered() async throws {
        let fixture = try await makeFixture()
        fixture.addPosition(1, mintBlock: 500)
        let first = try await fixture.fetch([1])
        #expect(try record(first, 1).1.history.mint?.number == 500)

        fixture.chain.reorg(from: 400, salt: "e")
        fixture.chain.addMint(1, to: Self.owner, block: 450)

        let (_, position) = try record(try await fixture.fetch([1], previous: previous(first)), 1)

        #expect(position.history.mint?.number == 450)
        #expect(position.history.mint?.hash == fixture.chain.hash(450))
    }

    @Test func ledgerMintWithAStaleHashIsIgnored() async throws {
        let fixture = try await makeFixture()
        fixture.addPosition(1, mintBlock: 500)

        let outcomes = try await fixture.fetch(
            [1],
            mints: [1: DefiMintEvidence(blockHash: "0xstale", blockNumber: 300)]
        )

        #expect(try record(outcomes, 1).1.history.mint?.number == 500)
    }

    @Test func tailReorgLeavesPersistedSumsAlone() async throws {
        let fixture = try await makeFixture()
        fixture.addPosition(1)
        fixture.chain.addCollect(1, 5, 5, block: 300)
        fixture.chain.addCollect(1, 7, 7, block: 995)

        let first = try await fixture.fetch([1])
        let (_, before) = try record(first, 1)
        #expect(before.history.collected == .init(5, 5))
        #expect(before.history.checkpoint?.number == 990)

        fixture.chain.reorg(from: 993, salt: "a")
        fixture.chain.addCollect(1, 11, 11, block: 996)

        let (_, after) = try record(try await fixture.fetch([1], previous: previous(first)), 1)
        #expect(after.history.collected == .init(5, 5))
        #expect(after.lifetimeFees == .init(16, 16))
    }

    @Test func reorganizedCheckpointRebuildsFromTheMint() async throws {
        let fixture = try await makeFixture()
        fixture.addPosition(1)
        fixture.chain.addCollect(1, 5, 5, block: 300)
        fixture.chain.addCollect(1, 9, 9, block: 980)
        let first = try await fixture.fetch([1])
        #expect(try record(first, 1).1.history.collected == .init(14, 14))

        fixture.chain.reorg(from: 950, salt: "b")
        fixture.chain.addCollect(1, 1, 1, block: 960)

        let (_, position) = try record(try await fixture.fetch([1], previous: previous(first)), 1)

        #expect(position.history.collected == .init(6, 6))
        #expect(position.history.checkpoint?.hash == fixture.chain.hash(990))
    }

    @Test func headReorgDuringTheRunWritesNothing() async throws {
        let fixture = try await makeFixture()
        fixture.addPosition(1)
        let chain = fixture.chain
        chain.onHeadRecheck = { chain.reorg(from: 999, salt: "c") }

        await #expect(throws: (any Error).self) {
            try await fixture.fetch([1])
        }
    }

    // MARK: - Budget

    @Test func budgetExhaustionAdvancesOnlyThroughCompletedRangesAndRotates() async throws {
        let fixture = try await makeFixture()
        fixture.chain.maxLogRange = 200_000
        fixture.addPosition(1, mintBlock: 100)
        fixture.addPosition(2, mintBlock: 100)
        fixture.chain.head = 1_000_000
        fixture.chain.addCollect(1, 1, 1, block: 150_000)

        // One log query: rotation 0 spends it on #1's first range.
        let first = try await fixture.fetch([1, 2], budget: 1, rotation: 0)
        let (_, one) = try record(first, 1)
        let (_, two) = try record(first, 2)
        #expect(one.historyState == .loading)
        #expect(two.historyState == .loading)
        #expect(two.history.mint == nil)

        // Rotation 1 starts with #2.
        let second = try await fixture.fetch([1, 2], previous: previous(first), budget: 1, rotation: 1)
        #expect(try record(second, 2).1.history.mint?.number == 100)

        let (_, settled) = try record(try await fixture.fetch([1, 2], previous: previous(second), budget: 100), 1)
        #expect(settled.historyState == .complete)
        #expect(settled.history.collected == .init(1, 1))
    }

    // MARK: - Pricing

    @Test func unpricedTokenMarksTheValuePartialAndBlanksAPR() async throws {
        let fixture = try await makeFixture(tokenSource: .init(price0: nil, price1: 1))
        fixture.addPosition(1)

        let (record, position) = try record(try await fixture.fetch([1]), 1)

        #expect(!record.isUSDValueComplete)
        #expect(position.valueUSD == nil)
        #expect(position.apr == nil)
    }
}
