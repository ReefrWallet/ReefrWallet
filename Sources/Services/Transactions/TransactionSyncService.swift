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

    private let balancesService: BalancesService
    private lazy var clientProvider = DI.injectOrFail(BlockchainClientProvider.self)
    private let databaseService: DatabaseService
    private var tasks: [PersistentIdentifier: Task<Void, Never>] = [:]
    private let transactionHistorySources: [any TransactionHistorySource]

    init(
        balancesService: BalancesService? = nil,
        databaseService: DatabaseService? = nil,
        transactionHistorySources: [any TransactionHistorySource] = [
            EtherscanTransactionHistorySource(),
            BlockscoutTransactionHistorySource(),
            SuiArchiveTransactionHistorySource()
        ]
    ) {
        let databaseService = databaseService ?? DI.injectOrFail(DatabaseService.self)
        self.balancesService = balancesService ?? BalancesService(databaseService: databaseService)
        self.databaseService = databaseService
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

        // Lower priority than the default so this doesn't contend equally
        // with main-actor/UI-driven work on the cooperative thread pool
        // during a large backfill.
        tasks[id] = Task(priority: .utility) { [weak self] in
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
            printError("\(account.name): \(error)")
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
                rpcURL: account.rpcURLOverride,
                backend: account.bitcoinBackend
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
            let state = try await databaseService.transactionSyncState(accountId: try accountId(account))

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

            try await commit(
                page,
                account: account,
                client: client,
                track: .descending,
                updatesBalances: false
            )

            // Backfill pages otherwise run back-to-back with no suspension
            // point, unlike the ascending track's idle sleep — yield so the
            // cooperative thread pool can schedule pending main-actor work
            // between pages.
            await Task.yield()

            if page.reachedBoundary {
                // Backfill spans many pages, each committed with `updatesBalances:
                // false` to avoid enqueueing on every page. Now that the whole
                // history is in, sweep every token this account is known to
                // hold once so none of the tokens discovered along the way are
                // left without a balance.
                await enqueueFullRefresh(account: account)
                return
            }
        }
    }

    func maintainForwardSync(account: Account, client: AnyBlockchainClient) async throws {
        while !Task.isCancelled {
            let state = try await databaseService.transactionSyncState(accountId: try accountId(account))
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

            try await commit(
                page,
                account: account,
                client: client,
                track: .ascending,
                updatesBalances: false
            )

            if page.reachedBoundary {
                // Idle poll: most iterations land here with an empty page.
                // `refreshBalances` is a no-op unless this page actually
                // carried transactions, so a quiet account no longer pays
                // for a full balance refresh every minute.
                await refreshBalances(account: account, transactions: page.transactions)
                // Standard HTTP JSON-RPC nodes are not guaranteed to expose
                // WebSocket pub-sub. Repeating the forward range scan is the
                // safe fallback; a future transactionSubscription capability
                // replaces this wait with an immediate node-head event.
                try await Task.sleep(for: .seconds(60))
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
                try await catchUp(
                    account: account,
                    client: client,
                    through: head.height,
                    updatesBalances: true
                )
            }
        } catch is CancellationError {
            return
        } catch {
            try await maintainForwardSync(account: account, client: client)
        }
    }

    func catchUpOnce(account: Account, client: AnyBlockchainClient) async {
        do {
            let state = try await databaseService.transactionSyncState(accountId: try accountId(account))

            if let currentHead = state.currentHead {
                try await catchUp(
                    account: account,
                    client: client,
                    through: currentHead,
                    updatesBalances: false
                )
            }
        } catch {
            await recordFailure(error, account: account)
        }
    }

    func catchUp(
        account: Account,
        client: AnyBlockchainClient,
        through head: UInt64,
        updatesBalances: Bool
    ) async throws {
        while !Task.isCancelled {
            let state = try await databaseService.transactionSyncState(accountId: try accountId(account))

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

            try await commit(
                page,
                account: account,
                client: client,
                track: .ascending,
                updatesBalances: updatesBalances
            )

            if page.reachedBoundary {
                if updatesBalances {
                    // Each page committed above already enqueued its own
                    // discovered tokens; this just links the last batch of
                    // effects and re-enqueues them (harmless — the queue
                    // dedupes) in case the account's client doesn't support
                    // bulk balances and the per-page enqueue lost a race.
                    await refreshBalances(account: account, transactions: page.transactions)
                } else {
                    // `catchUpOnce` committed every page with `updatesBalances:
                    // false`, so nothing was enqueued along the way — sweep
                    // every known token now that the gap is closed.
                    await enqueueFullRefresh(account: account)
                }
                return
            }
        }
    }

    func transactionHistory(
        account: Account,
        client: AnyBlockchainClient,
        request: BlockchainTransactionHistoryRequest
    ) async throws -> BlockchainTransactionPage {
        if account.rpcURLOverride == nil,
           let source = transactionHistorySources.first(where: { $0.supports(account) }) {
            return try await source.transactionHistory(account: account, request: request)
        }

        return try await client.transactionHistory(account.address, request: request)
    }

    func commit(
        _ page: BlockchainTransactionPage,
        account: Account,
        client: AnyBlockchainClient,
        track: Track,
        updatesBalances: Bool
    ) async throws {
        try await processTokenTransfers(page.transactions, account: account, client: client)

        let id = try accountId(account)
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
        // One save() covers both the transaction rows and the sync cursor —
        // a backfill page used to cost two separate write transactions (and
        // two main-thread @Query merges) for this.
        try await databaseService.saveTransactions(page.transactions, for: account, syncState: state)

        if updatesBalances {
            await enqueueBalanceUpdates(for: page.transactions, account: account)
        }
    }

    func recordFailure(_ error: any Swift.Error, account: Account) async {
        do {
            var state = try await databaseService.transactionSyncState(accountId: try accountId(account))
            state.lastError = error.localizedDescription
            try await databaseService.saveTransactionSyncState(state)
        } catch {
            printError("\(account.name): \(error)")
        }
    }

    /// Enqueues a balance update for every asset touched by `transactions`.
    /// A no-op when there are none, so idle polling that finds nothing new
    /// never reaches `BalancesService`.
    func refreshBalances(account: Account, transactions: [BlockchainTransaction]) async {
        guard !transactions.isEmpty else {
            return
        }

        do {
            try await databaseService.linkTransactionTokens(for: account)
        } catch {
            printError("\(account.name): \(error)")
        }

        await enqueueBalanceUpdates(for: transactions, account: account)
    }

    /// Sweeps every token this account is currently known to hold (native
    /// asset included) through the balance queue. Used at the handful of
    /// track-completion points where earlier pages were committed with
    /// `updatesBalances: false` and so never enqueued anything on their own —
    /// not on every idle iteration.
    func enqueueFullRefresh(account: Account) async {
        do {
            try await databaseService.linkTransactionTokens(for: account)
            let tokens = try await databaseService.fetchTokens(account: account)

            for token in tokens {
                await balancesService.enqueueBalanceUpdate(
                    account: account,
                    tokenAddress: token.address,
                    blockchain: account.blockchain
                )
            }
        } catch {
            printError("\(account.name): \(error)")
        }
    }

    func enqueueBalanceUpdates(for transactions: [BlockchainTransaction], account: Account) async {
        var tokenAddresses: Set<String?> = []

        for effect in transactions.flatMap(\.effects) {
            switch effect.kind {
            case .nativeTransfer:
                tokenAddresses.insert(nil)
            case .tokenTransfer:
                tokenAddresses.insert(effect.assetIdentifier)
            case .balanceChange, .tokenApproval, .unknown:
                continue
            }
        }

        for tokenAddress in tokenAddresses {
            await balancesService.enqueueBalanceUpdate(
                account: account,
                tokenAddress: tokenAddress,
                blockchain: account.blockchain
            )
        }
    }

    func accountId(_ account: Account) throws -> PersistentIdentifier {
        guard let id = account.id else {
            throw Error.invalidData
        }

        return id
    }

    /// Discovers and persists `TokenModel` rows for every token touched by
    /// `transactions`. Balance updates are handled separately by the caller
    /// (see `commit`) so backfill/catch-up pages can discover tokens without
    /// forcing a balance enqueue on every single page.
    func processTokenTransfers(
        _ transactions: [BlockchainTransaction],
        account: Account,
        client: AnyBlockchainClient
    ) async throws {
        try await processTokenTransfers(
            transactions
                .flatMap(\.effects)
                .filter { $0.kind == .tokenTransfer }
                .map { TokenTransfer(assetIdentifier: $0.assetIdentifier, rawPayload: $0.rawPayload) },
            account: account,
            client: client
        )
    }

    func processTokenTransfers(
        _ tokenEffects: [TokenTransfer],
        account: Account,
        client: AnyBlockchainClient
    ) async throws {
        let tokenAddresses = Set(tokenEffects.compactMap(\.assetIdentifier))

        guard !tokenAddresses.isEmpty else {
            return
        }

        for tokenAddress in tokenAddresses {
            guard try await databaseService.fetchToken(
                tokenAddress: tokenAddress,
                blockchain: account.blockchain
            ) == nil else {
                continue
            }

            let token = try await token(
                address: tokenAddress,
                effects: tokenEffects,
                blockchain: account.blockchain,
                client: client
            )
            try await databaseService.insertToken(token, blockchain: account.blockchain)
        }
    }

    func token(
        address: String,
        effects: [TokenTransfer],
        blockchain: WKBlockchain,
        client: AnyBlockchainClient
    ) async throws -> Token {
        let metadata: EtherscanTokenTransferMetadata? = effects.lazy.compactMap { effect in
            guard effect.assetIdentifier == address, let rawPayload = effect.rawPayload else {
                return nil
            }

            return try? JSONDecoder().decode(EtherscanTokenTransferMetadata.self, from: rawPayload)
        }.first

        if let metadata,
            let name = metadata.tokenName,
            let symbol = metadata.tokenSymbol {
            return Token(
                address: address,
                blockchain: blockchain,
                decimalsCount: UInt8(metadata.tokenDecimal ?? "") ?? 0,
                imageURL: nil,
                isHidden: false,
                isIncludedInBalance: true,
                isNativeToken: false,
                name: name,
                symbol: symbol,
                usdPrice: nil
            )
        }

        let tokenInfo = try await client.getTokenInfo(address)
        return Token(
            address: address,
            blockchain: blockchain,
            decimalsCount: tokenInfo.decimals,
            imageURL: nil,
            isHidden: false,
            isIncludedInBalance: true,
            isNativeToken: tokenInfo.isNative,
            name: tokenInfo.name,
            symbol: tokenInfo.symbol,
            usdPrice: nil
        )
    }
}

private struct EtherscanTokenTransferMetadata: Decodable {
    let tokenDecimal: String?
    let tokenName: String?
    let tokenSymbol: String?
}

private struct TokenTransfer {
    let assetIdentifier: String?
    let rawPayload: Data?
} // swiftlint:disable:this file_length
