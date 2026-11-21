//
//  DefiScheduler.swift
//  Reefr Wallet
//
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import Foundation
import SwiftData
import WalletKit

/// Runs DeFi plugins periodically and when an account's NFT ownership
/// changes, and writes their outcomes. See ADR-073.
actor DefiScheduler {
    static let historyBudget = 20
    static let interval = Duration.seconds(5 * 60)

    private struct RunKey: Hashable {
        let accountKey: String
        let kind: DefiPluginKind
    }

    private let databaseService: DatabaseService
    private var dirty: Set<RunKey> = []
    /// The NFT revision each account's last run read, to skip metadata-only saves.
    private var lastRevisions: [String: String] = [:]
    private var observeTask: Task<Void, Never>?
    private let plugins: [any DefiPlugin]
    private let requestNFTRefresh: @Sendable (Account) -> Void
    private var rotations: [RunKey: Int] = [:]
    private var running: Set<RunKey> = []
    private var sleepTask: Task<Void, Never>?
    private var task: Task<Void, Never>?

    init(
        databaseService: DatabaseService? = nil,
        plugins: [any DefiPlugin] = DefiPlugins.all,
        requestNFTRefresh: (@Sendable (Account) -> Void)? = nil
    ) {
        self.databaseService = databaseService ?? DI.injectOrFail(DatabaseService.self)
        self.plugins = plugins
        self.requestNFTRefresh = requestNFTRefresh ?? { account in
            DI.injectOrFail(NFTService.self).enqueueRefresh(account)
        }
    }

    func refreshNow() {
        sleepTask?.cancel()
    }

    func start() {
        guard task == nil else {
            return
        }

        printDebug("Starting periodic DeFi updates")

        task = Task(priority: .utility) { [weak self] in
            await RequestLane.$current.withValue(.balances) {
                await self?.loop()
            }
        }

        let container = databaseService.modelContainer
        observeTask = Task { @MainActor [weak self] in
            await container.observeSaves(affecting: ["NFTModel", "NFTPendingSendModel", "NFTScanModel"]) {
                await self?.ownershipMayHaveChanged()
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        observeTask?.cancel()
        observeTask = nil
        sleepTask?.cancel()
    }

    // MARK: - Runs

    /// One pass over all accounts: bootstraps NFT scans for candidates and runs
    /// plugins for eligible accounts.
    func runAll(now: Date = .now) async {
        let accounts: [Account]

        do {
            accounts = try await databaseService.fetchAllAccounts()
        } catch {
            printError("DeFi: cannot fetch accounts: \(error)")
            return
        }

        for account in accounts {
            await update(account, now: now)
        }
    }

    /// Bootstraps `account`'s NFT scan when stale and runs every eligible plugin.
    func update(_ account: Account, now: Date = .now) async {
        let candidates = plugins.filter { $0.isCandidate(account) }

        guard !candidates.isEmpty else {
            return
        }

        let scanStates: [NFTSourceId: NFTScanState]

        do {
            scanStates = try await databaseService.fetchNFTScanStates(account: account)
        } catch {
            printError("DeFi \(account.name): cannot read NFT scans: \(error)")
            return
        }

        if candidates.contains(where: { isScanStale($0, account: account, scanStates: scanStates, now: now) }) {
            requestNFTRefresh(account)
        }

        for plugin in candidates where plugin.isEligible(account, scanStates: scanStates) {
            await run(plugin, account: account)
        }
    }

    /// Runs `plugin` for `account`, coalescing a call made during a run into one rerun.
    func run(_ plugin: any DefiPlugin, account: Account) async {
        guard let accountKey = try? await databaseService.nftAccountKey(account: account) else {
            return
        }

        let key = RunKey(accountKey: accountKey, kind: plugin.kind)

        guard running.insert(key).inserted else {
            dirty.insert(key)
            return
        }

        defer {
            running.remove(key)
        }

        repeat {
            dirty.remove(key)
            await runOnce(plugin, account: account, key: key)
        } while dirty.contains(key) && !Task.isCancelled
    }

    // MARK: - Private

    private func isScanStale(
        _ plugin: any DefiPlugin,
        account: Account,
        scanStates: [NFTSourceId: NFTScanState],
        now: Date
    ) -> Bool {
        guard let source = plugin.requiredScanSource(account, scanStates: scanStates) else {
            return false
        }

        guard let scannedAt = scanStates[source]?.lastCompleteScanAt else {
            return true
        }

        return now.timeIntervalSince(scannedAt) >= TimeInterval(Self.interval.components.seconds)
    }

    private func loop() async {
        while !Task.isCancelled {
            await runAll()

            let sleeper = Task {
                _ = try? await Task.sleep(for: Self.interval)
            }

            sleepTask = sleeper
            await sleeper.value
            sleepTask = nil
        }
    }

    /// Re-runs accounts whose ownership revision moved since their last run.
    private func ownershipMayHaveChanged() async {
        guard task != nil, let accounts = try? await databaseService.fetchAllAccounts() else {
            return
        }

        for account in accounts where plugins.contains(where: { $0.isCandidate(account) }) {
            guard let input = try? await databaseService.defiInput(account: account),
                  lastRevisions[input.accountKey] != input.revision
            else {
                continue
            }

            for plugin in plugins where plugin.isCandidate(account) && plugin.isEligible(
                account,
                scanStates: input.scanStates
            ) {
                await run(plugin, account: account)
            }
        }
    }

    private func runOnce(_ plugin: any DefiPlugin, account: Account, key: RunKey) async {
        // A revision change between read and commit gets one immediate retry.
        for _ in 0 ..< 2 {
            do {
                let input = try await databaseService.defiInput(account: account)
                let rotation = rotations[key, default: 0]
                let context = DefiPluginContext(
                    account: account,
                    budget: DefiRequestBudget(Self.historyBudget),
                    input: input,
                    rotation: rotation
                )

                let outcomes = try await plugin.fetch(context)

                rotations[key] = rotation &+ 1
                lastRevisions[key.accountKey] = input.revision

                if try await databaseService.commitDefiOutcomes(
                    account: account,
                    kind: plugin.kind,
                    outcomes: outcomes,
                    expectedRevision: input.revision
                ) {
                    return
                }

                printVerbose("DeFi \(account.name) \(plugin.kind.rawValue): ownership changed during run, retrying")
            } catch is CancellationError {
                return
            } catch {
                printError("DeFi \(account.name) \(plugin.kind.rawValue): \(error)")
                return
            }
        }
    }
}
