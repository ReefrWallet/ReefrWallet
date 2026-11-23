//
//  DefiScheduler.swift
//  Reefr Wallet
//
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import Foundation
import SwiftData
import WalletKit

/// Refreshes every account's DeFi plugins periodically and on demand. See ADR-073.
actor DefiScheduler {
    static let interval = Duration.seconds(5 * 60)

    private struct RunKey: Hashable {
        let accountId: PersistentIdentifier
        let kind: DefiPluginKind
    }

    private let databaseService: DatabaseService
    private var dirty: Set<RunKey> = []
    private let makePlugins: @Sendable (Account) -> [any DefiPlugin]
    /// Kept while their account is unchanged, so plugins can keep state between runs.
    private var plugins: [RunKey: any DefiPlugin] = [:]
    private var running: Set<RunKey> = []
    private var sleepTask: Task<Void, Never>?
    private var task: Task<Void, Never>?

    init(
        databaseService: DatabaseService? = nil,
        plugins: (@Sendable (Account) -> [any DefiPlugin])? = nil
    ) {
        self.databaseService = databaseService ?? DI.injectOrFail(DatabaseService.self)
        makePlugins = plugins ?? { DefiPlugins.make(for: $0) }
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
    }

    func stop() {
        task?.cancel()
        task = nil
        sleepTask?.cancel()
    }

    // MARK: - Runs

    /// Refreshes every account's plugins once.
    func runAll() async {
        let accounts: [Account]

        do {
            accounts = try await databaseService.fetchAllAccounts()
        } catch {
            printError("DeFi: cannot fetch accounts: \(error)")
            return
        }

        let current = Set(accounts.compactMap(\.id))
        plugins = plugins.filter { current.contains($0.key.accountId) }

        for account in accounts {
            for plugin in plugins(for: account) {
                await run(plugin)
            }
        }
    }

    /// Refreshes `plugin`, coalescing a call made during a run into one rerun.
    func run(_ plugin: any DefiPlugin) async {
        guard let accountId = plugin.account.id else {
            return
        }

        let key = RunKey(accountId: accountId, kind: type(of: plugin).kind)

        guard running.insert(key).inserted else {
            dirty.insert(key)
            return
        }

        defer {
            running.remove(key)
        }

        repeat {
            dirty.remove(key)

            do {
                try await plugin.refresh()
            } catch is CancellationError {
                return
            } catch {
                printError("DeFi \(plugin.account.name) \(key.kind.rawValue): \(error)")
            }
        } while dirty.contains(key) && !Task.isCancelled
    }

    // MARK: - Private

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

    /// The account's plugins, reusing those made for the same account value.
    private func plugins(for account: Account) -> [any DefiPlugin] {
        guard let accountId = account.id else {
            return []
        }

        return makePlugins(account).map { made in
            let key = RunKey(accountId: accountId, kind: type(of: made).kind)

            if let kept = plugins[key], kept.account == account {
                return kept
            }

            plugins[key] = made
            return made
        }
    }
}
