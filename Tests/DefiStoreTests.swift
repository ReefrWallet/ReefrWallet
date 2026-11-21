// DeFi record store and scheduler: per-position outcomes, revision-checked
// commits, NFT-scan bootstrap and run coalescing (ADR-073).

import BigInt
import Foundation
import SwiftData
import Testing
import WalletKit
@testable import ReefrWallet

@Suite(.timeLimit(.minutes(1)))
struct DefiStoreTests {
    private static let owner = "0x" + String(repeating: "aa", count: 20)
    private static let other = "0x" + String(repeating: "bb", count: 20)
    private static let manager = "0xc36442b4a4522e871399cd717abdd847ab11fe88"
    private static let zero = "0x" + String(repeating: "00", count: 20)

    // MARK: - Helpers

    private func account(_ databaseService: DatabaseService, rpcURL: URL? = nil) async throws -> ReefrWallet.Account {
        try await makeStakingAccount(
            databaseService,
            blockchain: .evm(.ethereum(.mainnet)),
            address: Self.owner,
            rpcURL: rpcURL
        )
    }

    private func record(_ key: String, value: Decimal = 1) -> DefiPositionRecord {
        DefiPositionRecord(isUSDValueComplete: true, key: key, payload: Data(key.utf8), usdValue: value)
    }

    private func transfer(from: String, to: String, id: String, block: UInt64) -> NFTTransferEvent {
        NFTTransferEvent(
            amount: 1,
            batchPosition: 0,
            blockHash: "0xh\(block)",
            blockNumber: block,
            contract: Self.manager,
            from: from,
            logIndex: 0,
            source: NFTSourceId.node.rawValue,
            standard: .erc721,
            to: to,
            tokenId: id,
            transactionIndex: 0,
            txHash: "0xt\(id)-\(block)"
        )
    }

    private func commitLedger(
        _ databaseService: DatabaseService,
        _ account: ReefrWallet.Account,
        _ events: [NFTTransferEvent],
        source: NFTSourceId = .node,
        at date: Date = .now
    ) async throws {
        try await databaseService.commitNFTLedger(
            account: account,
            source: source,
            scan: NFTLedgerScan(events: events, fromBlock: 0, metadata: [:], scannedBlock: 1_000),
            startedAt: date
        )
    }

    // MARK: - Store

    @Test func oneCommitAppliesUpdatedFailedAndRemovedOutcomes() async throws {
        let databaseService = try makeDatabaseService()
        let account = try await account(databaseService)
        let revision = try await databaseService.defiInput(account: account).revision
        try await databaseService.commitDefiOutcomes(
            account: account,
            kind: .uniswapV3,
            outcomes: ["a", "b", "c", "d"].map { .updated(record($0)) },
            expectedRevision: revision
        )

        let applied = try await databaseService.commitDefiOutcomes(
            account: account,
            kind: .uniswapV3,
            outcomes: [.updated(record("a", value: 5)), .failed(key: "b"), .removed(key: "c")],
            expectedRevision: revision
        )

        let positions = try await databaseService.fetchDefiPositions(account: account)

        #expect(applied)
        #expect(positions.map(\.key) == ["a", "b", "d"])
        #expect(positions.first { $0.key == "a" }?.usdValue == 5)
        #expect(positions.first { $0.key == "b" }?.usdValue == 1)
    }

    @Test func accountTotalsIncludeDefiPositions() async throws {
        let databaseService = try makeDatabaseService()
        let account = try await account(databaseService)
        let accountId = try #require(account.id)
        let revision = try await databaseService.defiInput(account: account).revision
        try await databaseService.commitDefiOutcomes(
            account: account,
            kind: .uniswapV3,
            outcomes: [
                .updated(record("a", value: 1_684)),
                .updated(DefiPositionRecord(isUSDValueComplete: false, key: "b", payload: Data(), usdValue: nil))
            ],
            expectedRevision: revision
        )

        #expect(try await databaseService.accountUSDValues()[accountId] == 1_684)
        #expect(try await databaseService.usdValue(accountId: accountId) == 1_684)
    }

    @Test func ownershipChangeDuringARunVoidsItsCommit() async throws {
        let databaseService = try makeDatabaseService()
        let account = try await account(databaseService)
        try await commitLedger(
            databaseService,
            account,
            [transfer(from: Self.zero, to: Self.owner, id: "1", block: 10)]
        )

        let input = try await databaseService.defiInput(account: account)

        try await commitLedger(databaseService, account, [
            transfer(from: Self.zero, to: Self.owner, id: "1", block: 10),
            transfer(from: Self.owner, to: Self.other, id: "1", block: 20)
        ])

        let applied = try await databaseService.commitDefiOutcomes(
            account: account,
            kind: .uniswapV3,
            outcomes: [.updated(record("1:1"))],
            expectedRevision: input.revision
        )

        #expect(!applied)
        #expect(try await databaseService.fetchDefiPositions(account: account).isEmpty)
    }

    @Test func metadataWritesKeepTheRevision() async throws {
        let databaseService = try makeDatabaseService()
        let account = try await account(databaseService)
        try await commitLedger(
            databaseService,
            account,
            [transfer(from: Self.zero, to: Self.owner, id: "1", block: 10)]
        )

        let before = try await databaseService.defiInput(account: account)
        let key = try #require(before.nfts.first?.id)

        try await databaseService.applyNFTMetadata(key: key, name: "Position", imageURL: "https://example.com/1.svg", failedAt: nil)

        #expect(try await databaseService.defiInput(account: account).revision == before.revision)
    }

    @Test func ledgerMintsAreKeyedByNFT() async throws {
        let databaseService = try makeDatabaseService()
        let account = try await account(databaseService)
        try await commitLedger(
            databaseService,
            account,
            [transfer(from: Self.zero, to: Self.owner, id: "7", block: 42)]
        )

        let input = try await databaseService.defiInput(account: account)
        let key = try #require(input.nfts.first?.id)

        #expect(input.mints[key] == DefiMintEvidence(blockHash: "0xh42", blockNumber: 42))
    }

    @Test func positionsGoWithTheirAccount() async throws {
        let databaseService = try makeDatabaseService()
        let account = try await account(databaseService)
        let revision = try await databaseService.defiInput(account: account).revision
        try await databaseService.commitDefiOutcomes(
            account: account, kind: .uniswapV3, outcomes: [.updated(record("a"))], expectedRevision: revision
        )

        try await databaseService.deleteAccount(id: try #require(account.id))

        let remaining = try await MainActor.run {
            try databaseService.modelContainer.mainContext.fetchCount(FetchDescriptor<DefiPositionModel>())
        }
        #expect(remaining == 0)
    }

    // MARK: - Eligibility

    @Test func candidateAndEligibleOnBothPaths() async throws {
        let databaseService = try makeDatabaseService()
        let plugin = UniswapV3Plugin()
        let fresh = NFTScanState(lastCompleteScanAt: .now, scannedBlock: 1, isSnapshotSource: true)
        let node = URL(string: "http://localhost:8545")
        let mainnet = try await account(databaseService)
        let base = try await makeStakingAccount(databaseService, blockchain: .evm(.base(.mainnet)), address: Self.owner)
        let baseOverride = try await makeStakingAccount(
            databaseService, blockchain: .evm(.base(.mainnet)), address: Self.owner, rpcURL: node
        )

        #expect(plugin.isCandidate(mainnet))
        #expect(!plugin.isCandidate(base))
        #expect(plugin.isCandidate(baseOverride))
        #expect(!plugin.isEligible(mainnet, scanStates: [:]))
        #expect(plugin.isEligible(mainnet, scanStates: [.blockscout: fresh]))
        #expect(!plugin.isEligible(baseOverride, scanStates: [.blockscout: fresh]))
        #expect(plugin.isEligible(baseOverride, scanStates: [.node: fresh]))
        #expect(plugin.requiredScanSource(baseOverride, scanStates: [.blockscout: fresh]) == .node)
    }

    // MARK: - Scheduler

    @Test func coldStartBootstrapsTheNodeScanThenRuns() async throws {
        let databaseService = try makeDatabaseService()
        let account = try await account(databaseService, rpcURL: URL(string: "http://localhost:8545"))
        let plugin = RecordingPlugin()
        let refreshes = Counter()
        let scheduler = DefiScheduler(
            databaseService: databaseService,
            plugins: [plugin]
        ) { _ in refreshes.increment() }

        await scheduler.update(account)
        #expect(refreshes.value == 1)
        #expect(plugin.fetches.value == 0)

        try await commitLedger(
            databaseService,
            account,
            [transfer(from: Self.zero, to: Self.owner, id: "1", block: 10)]
        )

        await scheduler.update(account)

        #expect(refreshes.value == 1)
        #expect(plugin.fetches.value == 1)
        #expect(try await databaseService.fetchDefiPositions(account: account).map(\.key) == ["1"])
    }

    @Test func overrideAccountRetriesItsNodeAfterAFallback() async throws {
        let databaseService = try makeDatabaseService()
        let account = try await account(databaseService, rpcURL: URL(string: "http://localhost:8545"))
        try await commitLedger(databaseService, account, [], source: .node, at: .now.addingTimeInterval(-3_600))
        try await commitLedger(databaseService, account, [], source: .blockscout)
        let refreshes = Counter()
        let scheduler = DefiScheduler(
            databaseService: databaseService,
            plugins: [RecordingPlugin()]
        ) { _ in refreshes.increment() }

        await scheduler.update(account)

        #expect(refreshes.value == 1)
    }

    @Test func ownershipChangeMidRunRetriesOnceWithFreshInput() async throws {
        let databaseService = try makeDatabaseService()
        let account = try await account(databaseService)
        try await commitLedger(
            databaseService,
            account,
            [transfer(from: Self.zero, to: Self.owner, id: "1", block: 10)],
            source: .blockscout
        )

        let plugin = RecordingPlugin()
        plugin.beforeFirstReturn = {
            try? await commitLedger(databaseService, account, [
                transfer(from: Self.zero, to: Self.owner, id: "1", block: 10),
                transfer(from: Self.zero, to: Self.owner, id: "2", block: 11)
            ], source: .blockscout)
        }

        let scheduler = DefiScheduler(databaseService: databaseService, plugins: [plugin]) { _ in }

        await scheduler.run(plugin, account: account)

        #expect(plugin.fetches.value == 2)
        #expect(try await databaseService.fetchDefiPositions(account: account).map(\.key) == ["1", "2"])
    }

    @Test func triggersDuringARunCoalesceIntoOneRerun() async throws {
        let databaseService = try makeDatabaseService()
        let account = try await account(databaseService)
        let plugin = RecordingPlugin()
        let gate = Gate()
        plugin.gate = gate
        let scheduler = DefiScheduler(databaseService: databaseService, plugins: [plugin]) { _ in }

        async let first: Void = scheduler.run(plugin, account: account)
        await gate.waitUntilEntered()
        await scheduler.run(plugin, account: account)
        await scheduler.run(plugin, account: account)
        plugin.gate = nil
        await gate.open()
        await first

        #expect(plugin.fetches.value == 2)
    }
}

// MARK: - Fakes

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.withLock { count }
    }

    func increment() {
        lock.withLock { count += 1 }
    }
}

actor Gate {
    private var entered: CheckedContinuation<Void, Never>?
    private var hasEntered = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func enter() async {
        hasEntered = true
        entered?.resume()
        entered = nil
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        waiters.forEach { $0.resume() }
        waiters = []
    }

    func waitUntilEntered() async {
        guard !hasEntered else {
            return
        }

        await withCheckedContinuation { entered = $0 }
    }
}

/// Uniswap eligibility rules with a fetch that reports one record per input NFT.
final class RecordingPlugin: DefiPlugin, @unchecked Sendable {
    let fetches = Counter()
    let kind = DefiPluginKind.uniswapV3
    var beforeFirstReturn: (@Sendable () async -> Void)?
    var gate: Gate?

    private let rules = UniswapV3Plugin()

    func fetch(_ context: DefiPluginContext) async throws -> [DefiPositionOutcome] {
        fetches.increment()

        if let gate {
            await gate.enter()
        }

        if let hook = beforeFirstReturn {
            beforeFirstReturn = nil
            await hook()
        }

        return context.input.nfts.map {
            .updated(DefiPositionRecord(
                isUSDValueComplete: true,
                key: $0.reference.tokenId,
                payload: Data(),
                usdValue: 1
            ))
        }
    }

    func isCandidate(_ account: ReefrWallet.Account) -> Bool {
        rules.isCandidate(account)
    }

    func isEligible(_ account: ReefrWallet.Account, scanStates: [NFTSourceId: NFTScanState]) -> Bool {
        rules.isEligible(account, scanStates: scanStates)
    }

    func requiredScanSource(_ account: ReefrWallet.Account, scanStates: [NFTSourceId: NFTScanState]) -> NFTSourceId? {
        rules.requiredScanSource(account, scanStates: scanStates)
    }
}
