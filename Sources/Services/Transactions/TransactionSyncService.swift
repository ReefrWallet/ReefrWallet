//
//  TransactionSyncService.swift
//  Reefr Wallet
//

import Foundation
import SwiftData
import WalletKit

/// Coordinates durable transaction recovery for every wallet account.
///
/// History and forward recovery deliberately have independent persisted
/// cursors: the descending task must never jump back to a newer head after an
/// interruption, while the ascending task closes the gap to the live head.
actor TransactionSyncService {
    enum Track {
        case descending
        case ascending
    }

    private lazy var clientProvider = DI.injectOrFail(BlockchainClientProvider.self)
    private let databaseService: DatabaseService
    private var tasks: [PersistentIdentifier: Task<Void, Never>] = [:]
    private let transactionHistorySources: [any TransactionHistorySource]

    init(
        databaseService: DatabaseService? = nil,
        transactionHistorySources: [any TransactionHistorySource] = [BlockscoutTransactionHistorySource()]
    ) {
        self.databaseService = databaseService ?? DI.injectOrFail(DatabaseService.self)
        self.transactionHistorySources = transactionHistorySources
    }

    func startAll() async {
        do {
            let accounts = try await databaseService.fetchAllAccounts()
            for account in accounts {
                start(account)
            }
        } catch {
            printError(error)
        }
    }

    func start(_ account: Account) {
        guard let id = account.id, tasks[id] == nil else {
            return
        }

        printDebug("Starting transaction history fetching for \(account.name)")

        tasks[id] = Task { [weak self] in
            await self?.synchronize(account)
            await self?.finish(id)
        }
    }

    func stop(_ account: Account) {
        guard let id = account.id else {
            return
        }

        printDebug("Stopping transaction history fetching for \(account.name)")

        tasks.removeValue(forKey: id)?.cancel()
    }

    func recordBroadcast(identifier: String, account: Account) async {
        let transaction = BlockchainTransaction(identifier: identifier, status: .broadcast)

        do {
            try await databaseService.saveTransactions([transaction], for: account)
        } catch {
            printError(error)
        }
    }
}

private extension TransactionSyncService {
    func finish(_ id: PersistentIdentifier) {
        tasks[id] = nil
    }

    func synchronize(_ account: Account) async {
        do {
            let client = try await clientProvider.getClient(
                blockchain: account.blockchain,
                rpcURL: account.rpcURLOverride
            )

            guard client.isSupported(.transactionHistory) else {
                printDebug("Transaction history not supported for \(account.name)")
                return
            }

            async let descending: Void = scanDescending(account: account, client: client)
            async let ascending: Void = client.isSupported(.transactionSubscription)
                ? maintainSubscription(account: account, client: client)
                : maintainForwardSync(account: account, client: client)

            _ = try await (descending, ascending)
        } catch is CancellationError {
            return
        } catch {
            await recordFailure(error, account: account)
        }
    }

    func scanDescending(account: Account, client: AnyBlockchainClient) async throws {
        while !Task.isCancelled {
            let state = try await databaseService.transactionSyncState(accountId: try accountID(account))

            guard !state.backfillComplete else {
                printDebug("Backfill complete for \(account.name)")
                return
            }

            let page = try await transactionHistory(
                account: account,
                client: client,
                request: BlockchainTransactionHistoryRequest(
                    cursor: state.descendingCursor,
                    direction: .descending,
                    lowerBound: 0,
                    upperBound: state.initialBackfillHead
                )
            )

            try await commit(page, account: account, track: .descending)

            if page.reachedBoundary {
                return
            }
        }
    }

    func maintainForwardSync(account: Account, client: AnyBlockchainClient) async throws {
        while !Task.isCancelled {
            let state = try await databaseService.transactionSyncState(accountId: try accountID(account))
            guard let currentHead = state.currentHead else {
                // Let the descending track establish its immutable first
                // head. This is intentionally not a reset to the current tip.
                try await Task.sleep(for: .seconds(1))
                continue
            }

            let page = try await client.transactionHistory(
                account.address,
                request: BlockchainTransactionHistoryRequest(
                    cursor: state.ascendingCursor,
                    direction: .ascending,
                    lowerBound: currentHead + 1
                )
            )

            try await commit(page, account: account, track: .ascending)

            if page.reachedBoundary {
                // Standard HTTP JSON-RPC nodes are not guaranteed to expose
                // WebSocket pub-sub. Repeating the forward range scan is the
                // safe fallback; a future transactionSubscription capability
                // replaces this wait with an immediate node-head event.
                try await Task.sleep(for: .seconds(10))
            }
        }
    }

    func maintainSubscription(account: Account, client: AnyBlockchainClient) async throws {
        // The stream only delivers future heads. Before consuming it, scan
        // forward once from the durable cursor to close any previous-session
        // gap. Construct the stream first so its task buffers heads created
        // during that recovery window.
        let heads = client.transactionHeads(account.address)
        await catchUpOnce(account: account, client: client)

        do {
            for try await head in heads {
                try await catchUp(account: account, client: client, through: head.height)
            }
        } catch is CancellationError {
            return
        } catch {
            try await maintainForwardSync(account: account, client: client)
        }
    }

    func catchUpOnce(account: Account, client: AnyBlockchainClient) async {
        do {
            let state = try await databaseService.transactionSyncState(accountId: try accountID(account))

            if let currentHead = state.currentHead {
                try await catchUp(account: account, client: client, through: currentHead)
            }
        } catch {
            await recordFailure(error, account: account)
        }
    }

    func catchUp(account: Account, client: AnyBlockchainClient, through head: UInt64) async throws {
        while !Task.isCancelled {
            let state = try await databaseService.transactionSyncState(accountId: try accountID(account))

            guard let currentHead = state.currentHead, currentHead < head else {
                return
            }

            let page = try await client.transactionHistory(
                account.address,
                request: BlockchainTransactionHistoryRequest(
                    direction: .ascending,
                    lowerBound: currentHead + 1,
                    upperBound: head
                )
            )

            try await commit(page, account: account, track: .ascending)

            if page.reachedBoundary {
                return
            }
        }
    }

    func transactionHistory(
        account: Account,
        client: AnyBlockchainClient,
        request: BlockchainTransactionHistoryRequest
    ) async throws -> BlockchainTransactionPage {
        if let source = transactionHistorySources.first(where: { $0.supports(account) }) {
            return try await source.transactionHistory(account: account, request: request)
        }

        return try await client.transactionHistory(account.address, request: request)
    }

    func commit(_ page: BlockchainTransactionPage, account: Account, track: Track) async throws {
        try await databaseService.saveTransactions(page.transactions, for: account)
        let id = try accountID(account)
        var state = try await databaseService.transactionSyncState(accountId: id)

        switch track {
        case .descending:
            if state.initialBackfillHead == nil {
                state.initialBackfillHead = page.head
            }

            state.descendingCursor = page.nextCursor
            state.backfillComplete = page.reachedBoundary
        case .ascending:
            state.ascendingCursor = page.nextCursor
        }

        if let head = page.head {
            state.currentHead = max(state.currentHead ?? 0, head)
        }

        state.lastError = nil
        try await databaseService.saveTransactionSyncState(state)
    }

    func recordFailure(_ error: any Swift.Error, account: Account) async {
        do {
            var state = try await databaseService.transactionSyncState(accountId: try accountID(account))
            state.lastError = error.localizedDescription
            try await databaseService.saveTransactionSyncState(state)
        } catch {
            printError(error)
        }
    }

    func accountID(_ account: Account) throws -> PersistentIdentifier {
        guard let id = account.id else {
            throw Error.invalidData
        }

        return id
    }
}
