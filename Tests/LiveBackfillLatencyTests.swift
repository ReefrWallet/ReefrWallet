// Opt-in live measurement: refresh latency while a large transaction backfill is running.
//
// Runs against real mainnet services, so it is off unless `REEFR_LIVE_LATENCY` is set or the
// sentinel file `/private/tmp/reefr-live-latency` exists. Results are printed, not asserted:
// they depend on the providers' load. Approvals are measured only when an Etherscan key is
// available (`ETHERSCAN_API_KEY` or the app's stored key).

import Foundation
@testable import ReefrWallet
import SwiftData
import Testing
import WalletKit

private enum LiveLatency {
    static var isEnabled: Bool {
        ProcessInfo.processInfo.environment["REEFR_LIVE_LATENCY"] != nil
            || FileManager.default.fileExists(atPath: "/private/tmp/reefr-live-latency")
    }
}

@Suite(.enabled(if: LiveLatency.isEnabled), .serialized, .timeLimit(.minutes(5)))
struct LiveBackfillLatencyTests {
    struct Subject: Sendable, CustomTestStringConvertible {
        let name: String
        let address: String

        var testDescription: String { name }
    }

    static let subjects = [
        Subject(name: "vitalik.eth", address: "0xd8dA6BF26964aF9D7eEd9e03E53415D37aA96045"),
        Subject(name: "test-junk-#1", address: "0x70997970C51812dc3A010C7d01b50e0d17dc79C8")
    ]

    @Test(arguments: subjects)
    // swiftlint:disable:next function_body_length
    func refreshWhileBackfilling(_ subject: Subject) async throws {
        let apiKey = ProcessInfo.processInfo.environment["ETHERSCAN_API_KEY"]
            ?? UserDefaults.standard.string(forKey: EtherscanTransactionHistorySource.apiKeyDefaultsKey)
        let previousKey = UserDefaults.standard.string(forKey: EtherscanTransactionHistorySource.apiKeyDefaultsKey)

        if let apiKey {
            UserDefaults.standard.set(apiKey, forKey: EtherscanTransactionHistorySource.apiKeyDefaultsKey)
        }

        defer { UserDefaults.standard.set(previousKey, forKey: EtherscanTransactionHistorySource.apiKeyDefaultsKey) }

        let databaseService = try makeDatabaseService()
        let keyStore = try await databaseService.watchOnlyKeyStore()
        let keyStoreId = try #require(keyStore.id)
        var account = Account(
            address: subject.address,
            blockchain: .evm(.ethereum(.mainnet)),
            derivationPath: nil,
            keyStoreId: keyStoreId,
            name: subject.name
        )

        account.id = try await databaseService.insertAccount(account, keyStore: keyStore)
        let accountId = try #require(account.id)
        let watched = account

        let balancesService = BalancesService(databaseService: databaseService)
        let approvalService = EthereumApprovalService(databaseService: databaseService)
        let hasApprovals = approvalService.supports(watched)

        func refresh(_ label: String) async -> (balances: Duration?, approvals: Duration?) {
            async let approvals: Duration? = hasApprovals
                ? Self.measure("\(label) approvals") { try await approvalService.updateApprovals(watched) }
                : nil

            let balances = await Self.measure("\(label) balances") { try await balancesService.updateBalances(watched) }
            return (balances, await approvals)
        }

        let baseline = await refresh("baseline")
        let statsBefore = await RateGateRegistry.shared.admissionStats()

        let service = TransactionSyncService(databaseService: databaseService)
        await service.start(watched)

        // Let the backfill get going, then refresh in the middle of it.
        let started = ContinuousClock.now
        while ContinuousClock.now - started < .seconds(15) {
            if try await databaseService.fetchTransactions(accountId: accountId).count >= 50 {
                break
            }

            try await Task.sleep(for: .milliseconds(250))
        }

        let storedBeforeRefresh = try await databaseService.fetchTransactions(accountId: accountId).count
        let contended = await refresh("contended")
        try await Task.sleep(for: .seconds(5))
        await service.stop(watched)

        let state = try await databaseService.transactionSyncState(accountId: accountId)
        let stored = try await databaseService.fetchTransactions(accountId: accountId).count
        let statsAfter = await RateGateRegistry.shared.admissionStats()

        var report = "LIVE LATENCY \(subject.name) (approvals measured: \(hasApprovals))\n"
        report += "  baseline refresh (no backfill): balances \(describe(baseline.balances)), "
        report += "approvals \(describe(baseline.approvals))\n"
        report += "  refresh during backfill (\(storedBeforeRefresh) txs stored): "
        report += "balances \(describe(contended.balances)), approvals \(describe(contended.approvals))\n"
        report += "  backfill: \(stored) txs stored, complete \(state.backfillComplete), last error \(state.lastError ?? "none")\n"

        for key in statsAfter.keys.sorted() {
            for lane in RequestLane.allCases {
                let after = statsAfter[key]?[lane]
                let before = statsBefore[key]?[lane] ?? LaneAdmissionStats()

                guard let after, after.count > before.count else {
                    continue
                }

                let count = after.count - before.count
                let wait = after.totalWait - before.totalWait
                let cooldown = after.totalCooldownWait - before.totalCooldownWait
                report += "  \(key) [\(lane.rawValue)] admissions \(count), mean wait excl. cooldown "
                report += "\((wait - cooldown) / count), max wait \(after.maxWait), cooldown wait \(cooldown)\n"
            }
        }

        printDebug(report)
    }

    private func describe(_ duration: Duration?) -> String {
        guard let duration else {
            return "failed, timed out or n/a"
        }

        return duration.formatted(.units(allowed: [.seconds, .milliseconds], width: .abbreviated))
    }

    /// Runs `operation`, giving up (and cancelling it) after 45 s so a stall can't eat the suite's time limit.
    /// Returns a duration only when it succeeds: a fast failure must not look like a fast refresh.
    private static func measure(
        _ label: String,
        _ operation: @escaping @Sendable () async throws -> Void
    ) async -> Duration? {
        let finished = Finished()
        let start = ContinuousClock.now
        let task = Task {
            do {
                try await operation()
                // Stamped here, not when the polling loop below notices.
                await finished.mark(elapsed: ContinuousClock.now - start)
            } catch {
                await finished.fail("\(error)")
            }
        }

        while !(await finished.isDone), ContinuousClock.now - start < .seconds(45) {
            try? await Task.sleep(for: .milliseconds(200))
        }

        if let failure = await finished.failure {
            printDebug("LIVE LATENCY FAILED: \(label): \(failure)")
            return nil
        }

        guard let elapsed = await finished.elapsed else {
            task.cancel()
            printDebug("LIVE LATENCY TIMEOUT: \(label)")
            return nil
        }

        return elapsed
    }
}

private actor Finished {
    private(set) var elapsed: Duration?
    private(set) var failure: String?

    var isDone: Bool { elapsed != nil || failure != nil }

    func mark(elapsed: Duration) {
        self.elapsed = elapsed
    }

    func fail(_ message: String) {
        failure = message
    }
}
