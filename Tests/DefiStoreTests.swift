// DeFi record store and scheduler: per-position outcomes, ledger mints,
// supported blockchains, plugin reuse and run coalescing (ADR-073).

import BigInt
import Foundation
import SwiftData
import SwiftUI
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
        DefiPositionRecord(key: key, payload: Data(key.utf8), usdValue: value)
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

    @Test func oneSaveAppliesUpdatedFailedAndRemovedOutcomes() async throws {
        let databaseService = try makeDatabaseService()
        let account = try await account(databaseService)
        try await databaseService.saveDefiOutcomes(
            account: account,
            kind: .uniswapV3,
            ["a", "b", "c", "d"].map { .updated(record($0)) }
        )

        try await databaseService.saveDefiOutcomes(
            account: account,
            kind: .uniswapV3,
            [.updated(record("a", value: 5)), .failed(key: "b"), .removed(key: "c")]
        )

        let positions = try await databaseService.fetchDefiPositions(account: account)

        #expect(positions.map(\.key) == ["a", "b", "d"])
        #expect(positions.first { $0.key == "a" }?.usdValue == 5)
        #expect(positions.first { $0.key == "b" }?.usdValue == 1)
    }

    @Test func accountTotalsIncludeDefiPositions() async throws {
        let databaseService = try makeDatabaseService()
        let account = try await account(databaseService)
        let accountId = try #require(account.id)
        try await databaseService.saveDefiOutcomes(
            account: account,
            kind: .uniswapV3,
            [.updated(record("a", value: 1_684)), .updated(record("b", value: 0))]
        )

        #expect(try await databaseService.accountUSDValues()[accountId] == 1_684)
        #expect(try await databaseService.usdValue(accountId: accountId) == 1_684)
    }

    @Test func positionsAreReadByKind() async throws {
        let databaseService = try makeDatabaseService()
        let account = try await account(databaseService)
        try await databaseService.saveDefiOutcomes(account: account, kind: .uniswapV3, [.updated(record("a"))])
        try await databaseService.saveDefiOutcomes(account: account, kind: .hyperliquid, [.updated(record("b"))])

        let uniswap = try await databaseService.fetchDefiPositions(account: account, kind: .uniswapV3)
        let all = try await databaseService.fetchDefiPositions(account: account)

        #expect(uniswap.map(\.key) == ["a"])
        #expect(all.map(\.key) == ["b", "a"])
    }

    @Test func ledgerMintsAreKeyedByNFT() async throws {
        let databaseService = try makeDatabaseService()
        let account = try await account(databaseService)
        try await commitLedger(
            databaseService,
            account,
            [transfer(from: Self.zero, to: Self.owner, id: "7", block: 42)]
        )

        let key = try #require(try await databaseService.fetchNFTs(account: account).first?.id)

        #expect(try await databaseService.fetchNFTMints(account: account)[key] == NFTMint(
            blockHash: "0xh42",
            blockNumber: 42
        ))
    }

    @Test func positionsGoWithTheirAccount() async throws {
        let databaseService = try makeDatabaseService()
        let account = try await account(databaseService)
        try await databaseService.saveDefiOutcomes(account: account, kind: .uniswapV3, [.updated(record("a"))])

        try await databaseService.deleteAccount(id: try #require(account.id))

        let remaining = try await MainActor.run {
            try databaseService.modelContainer.mainContext.fetchCount(FetchDescriptor<DefiPositionModel>())
        }
        #expect(remaining == 0)
    }

    // MARK: - Plugins

    @Test func supportedBlockchainsPickThePlugins() {
        let kinds = { (blockchain: Blockchain) in
            DefiPlugins.types.filter { $0.isSupported(blockchain) }.map { $0.kind }
        }

        #expect(kinds(.evm(.ethereum(.mainnet))) == [.revertLend, .uniswapV3])
        #expect(kinds(.evm(.ethereum(.sepolia))) == [.uniswapV3])
        #expect(kinds(.evm(.hyperEVM(.mainnet))) == [.hyperliquid])
        #expect(kinds(.solana(.mainnet)).isEmpty)
    }

    // MARK: - Scheduler

    @Test func schedulerKeepsPluginsWhileTheAccountIsUnchanged() async throws {
        let databaseService = try makeDatabaseService()
        _ = try await account(databaseService)
        let made = Made()
        let scheduler = DefiScheduler(databaseService: databaseService) { account in
            [made.add(RecordingPlugin(account: account))]
        }

        await scheduler.runAll()
        await scheduler.runAll()

        let plugins = made.plugins
        #expect(plugins.count == 2)
        #expect(plugins.map(\.refreshes.value) == [2, 0])
    }

    @Test func triggersDuringARunCoalesceIntoOneRerun() async throws {
        let databaseService = try makeDatabaseService()
        let account = try await account(databaseService)
        let plugin = RecordingPlugin(account: account)
        let gate = Gate()
        plugin.gate = gate
        let scheduler = DefiScheduler(databaseService: databaseService) { _ in [] }

        async let first: Void = scheduler.run(plugin)
        await gate.waitUntilEntered()
        await scheduler.run(plugin)
        await scheduler.run(plugin)
        plugin.gate = nil
        await gate.open()
        await first

        #expect(plugin.refreshes.value == 2)
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

/// Every plugin a scheduler's factory made, in order.
final class Made: @unchecked Sendable {
    private let lock = NSLock()
    private var made: [RecordingPlugin] = []

    var plugins: [RecordingPlugin] {
        lock.withLock { made }
    }

    func add(_ plugin: RecordingPlugin) -> RecordingPlugin {
        lock.withLock { made.append(plugin) }
        return plugin
    }
}

/// Counts refreshes; a gate can hold one open.
final class RecordingPlugin: DefiPlugin, @unchecked Sendable {
    static let kind = DefiPluginKind.uniswapV3

    let account: ReefrWallet.Account
    let refreshes = Counter()
    var gate: Gate?

    init(account: ReefrWallet.Account) {
        self.account = account
    }

    static func isSupported(_ blockchain: Blockchain) -> Bool {
        true
    }

    func refresh() async throws {
        refreshes.increment()

        if let gate {
            await gate.enter()
        }
    }

    func view(_ position: DefiPosition) -> some View {
        EmptyView()
    }
}
