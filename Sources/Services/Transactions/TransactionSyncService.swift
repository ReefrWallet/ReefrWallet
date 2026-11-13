// swiftlint:disable file_length
//
//  TransactionSyncService.swift
//  Reefr Wallet
//

import SwiftData
import WalletKit

/// Coordinates durable transaction recovery for every wallet account.
///
/// History and forward recovery deliberately have independent persisted
/// cursors: the descending task must never jump back to a newer head after an
/// interruption, while the ascending task closes the gap to the live head.
actor TransactionSyncService {
    static let idlePollInterval = Duration.seconds(60)
    static let idlePollSpacing = Duration.seconds(2)

    enum Track {
        case descending
        case ascending
    }

    private let balancesService: BalancesService
    private let clientProvider: BlockchainClientProvider
    private let databaseService: DatabaseService
    private var nextBackfillWrite = ContinuousClock.now
    private var nextIdlePoll = ContinuousClock.now
    private var tasks: [PersistentIdentifier: Task<Void, Never>] = [:]
    private let transactionHistorySources: [any TransactionHistorySource]

    init(
        balancesService: BalancesService? = nil,
        clientProvider: BlockchainClientProvider? = nil,
        databaseService: DatabaseService? = nil,
        transactionHistorySources: [any TransactionHistorySource] = [
            EtherscanTransactionHistorySource(),
            BlockscoutTransactionHistorySource(),
            SuiArchiveTransactionHistorySource()
        ]
    ) {
        let databaseService = databaseService ?? DI.injectOrFail(DatabaseService.self)
        self.balancesService = balancesService ?? BalancesService(databaseService: databaseService)
        self.clientProvider = clientProvider ?? DI.injectOrFail(BlockchainClientProvider.self)
        self.databaseService = databaseService
        self.transactionHistorySources = transactionHistorySources
    }

    func startAll() async {
        do {
            try await databaseService.normalizeTransactionStableIds()
        } catch {
            printError(error)
        }

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

        // Keep the task registered until both tracks finish unwinding.
        tasks[id]?.cancel()
    }

    /// Clears a Sui staking transaction proven never to have run: its pending claim and its history
    /// placeholder, together. Chain history will never return it.
    ///
    /// - Throws: if it can't be saved; the claim is then still there, so the caller can retry.
    func clearNonExecutedSuiSubmission(digest: String, account: Account) async throws {
        try await databaseService.clearNonExecutedSuiSubmission(digest: digest, for: account)
    }

    /// Like ``recordBroadcast(identifier:account:)`` for a Sui staking transaction, written only while its
    /// submission is still pending, so cleanup after a proven non-execution can't be undone by a late send.
    func recordPendingSuiBroadcast(digest: String, account: Account) async {
        do {
            try await databaseService.recordSuiBroadcast(digest: digest, for: account)
        } catch {
            printError("\(account.name): \(error)")
        }
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
            let client = try clientProvider.makeClient(
                blockchain: account.blockchain,
                rpcURL: account.rpcURLOverride,
                backend: account.bitcoinBackend
            )

            guard client.isSupported(.transactionHistory) else {
                printDebug("Transaction history not supported for \(account.name)")
                return
            }

            async let descending: Void = RequestLane.$current.withValue(.backfill) {
                try await scanDescending(account: account, client: client)
            }

            async let ascending: Void = RequestLane.$current.withValue(.polling) {
                try await client.isSupported(.transactionSubscription)
                    ? maintainSubscription(account: account, client: client)
                    : maintainForwardSync(account: account, client: client)
            }

            _ = try await (descending, ascending)
        } catch is CancellationError {
            return
        } catch {
            await recordFailure(error, account: account)
        }
    }

    func scanDescending(account: Account, client: any BlockchainClientProtocol) async throws {
        var restartsHeadlessBackfill = true

        while !Task.isCancelled {
            var state = try await databaseService.transactionSyncState(accountId: try accountId(account))

            // A backfill that finished without a head (older Tron client) stalls forward
            // sync forever. Rerun it once per session to establish one.
            if state.backfillComplete, state.currentHead == nil, restartsHeadlessBackfill {
                restartsHeadlessBackfill = false
                state.backfillComplete = false
                state.descendingCursor = nil
                state.initialBackfillHead = nil
                try await databaseService.saveTransactionSyncState(state)
            }

            guard !state.backfillComplete else {
                printDebug("Backfill complete for \(account.name)")

                if state.tokenBackfillVersion < 1 {
                    await runTokenTransferBackfill(account: account, client: client)
                }

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

            if state.currentHead != nil || state.descendingCursor != nil {
                try await paceBackfillWrite()
            }

            try await commit(
                page,
                account: account,
                client: client,
                track: .descending,
                updatesBalances: false
            )

            // The newest page is committed first. Refresh it immediately so
            // a current receipt is reflected even while an archive backfill
            // continues through older activity.
            if state.currentHead == nil {
                await refreshBalances(account: account, transactions: page.transactions)
            }

            if page.nextCursor == state.descendingCursor, !page.reachedBoundary {
                // A node can list a confirmed signature before it serves the
                // transaction detail. Its client deliberately keeps the
                // cursor unchanged so this retry cannot skip the activity.
                try await Task.sleep(for: .seconds(1))
            }

            if page.reachedBoundary {
                try await completeBackfill(account: account)
                return
            }
        }
    }

    /// The merged backfill covers ERC-20 transfers, so no separate pass is owed; sweeps the
    /// balances of every token found along the way.
    func completeBackfill(account: Account) async throws {
        // The merged backfill covers ERC-20 transfers; no separate pass is owed.
        try await databaseService.saveTokenBackfillProgress(
            accountId: try accountId(account),
            cursor: nil,
            complete: true
        )

        // Backfill spans many pages, each committed with `updatesBalances:
        // false` to avoid enqueueing on every page. Now that the whole
        // history is in, sweep every token this account is known to
        // hold once so none of the tokens discovered along the way are
        // left without a balance.
        await enqueueFullRefresh(account: account)
    }

    /// Space history writes across accounts so their SwiftData merges leave time for UI work.
    /// The first page can establish the live cursor immediately.
    func paceBackfillWrite() async throws {
        let slot = max(nextBackfillWrite, .now)
        nextBackfillWrite = slot + .seconds(1)
        try await Task.sleep(until: slot, clock: .continuous)
    }

    func waitForIdlePollSlot() async throws {
        try await Task.sleep(for: Self.idlePollInterval)

        let slot = max(nextIdlePoll, .now)
        nextIdlePoll = slot + Self.idlePollSpacing
        try await Task.sleep(until: slot, clock: .continuous)
    }

    func maintainForwardSync(account: Account, client: any BlockchainClientProtocol) async throws {
        var hasRefreshedAllBalances = false

        while !Task.isCancelled {
            guard try await scanForward(
                account: account,
                client: client,
                through: nil,
                rewindsToLatestTransaction: !hasRefreshedAllBalances
            ) else {
                // Let the descending track establish its immutable first
                // head. This is intentionally not a reset to the current tip.
                try await Task.sleep(for: .seconds(1))
                continue
            }

            if !hasRefreshedAllBalances {
                // Balances may have changed while the app wasn't running in ways
                // no scanned transaction reveals (e.g. an indexer gap).
                hasRefreshedAllBalances = true
                await enqueueFullRefresh(account: account)
            }

            if case .ton = account.blockchain {
                await DI.inject(TonSendService.self)?.reconcile(account: account)
            }

            // Standard HTTP JSON-RPC nodes are not guaranteed to expose
            // WebSocket pub-sub. Space fallback polls across accounts so a
            // quiet wallet does not wake every client and SwiftData at once.
            try await waitForIdlePollSlot()
        }
    }

    func maintainSubscription(account: Account, client: any BlockchainClientProtocol) async throws {
        // The stream only delivers future heads. Before consuming it, close
        // the gap since the previous session up to the current tip. Construct
        // the stream first so its task buffers heads created meanwhile.
        let heads = client.transactionHeads(account.address)
        await catchUpOnce(account: account, client: client)

        do {
            for try await head in heads {
                try await scanForward(account: account, client: client, through: head.height)
            }
        } catch is CancellationError {
            return
        } catch {
            try await maintainForwardSync(account: account, client: client)
        }
    }

    /// Closes the gap left while the app wasn't running: scans from the durable
    /// forward position to the node's current tip, waiting for the descending
    /// track to establish the first head if needed.
    func catchUpOnce(account: Account, client: any BlockchainClientProtocol) async {
        do {
            while !Task.isCancelled {
                let hasHead = try await scanForward(
                    account: account,
                    client: client,
                    through: nil,
                    rewindsToLatestTransaction: true
                )

                if hasHead {
                    // Balances may have changed while the app wasn't running in
                    // ways no scanned transaction reveals (e.g. an indexer gap).
                    await enqueueFullRefresh(account: account)
                    return
                }

                try await Task.sleep(for: .seconds(1))
            }
        } catch is CancellationError {
            return
        } catch {
            await recordFailure(error, account: account)
        }
    }

    /// Scans forward page by page from the persisted ascending cursor (or
    /// `currentHead + 1`) through `head` (`nil` means the source's current tip),
    /// then refreshes the balances of every asset the scan touched.
    ///
    /// `currentHead` only advances once a range is fully scanned, so an
    /// interrupted or multi-page scan never skips blocks.
    ///
    /// - Returns: `false` when no head is established yet (backfill pending).
    ///
    /// - Parameter rewindsToLatestTransaction: Starts an indexer-backed scan just past
    ///   the newest stored transaction instead of `currentHead`, re-covering any
    ///   range an earlier version marked scanned without scanning it.
    @discardableResult
    func scanForward(
        account: Account,
        client: any BlockchainClientProtocol,
        through head: UInt64?,
        rewindsToLatestTransaction: Bool = false
    ) async throws -> Bool {
        var touched: [BlockchainTransaction] = []
        var rewindHead = rewindsToLatestTransaction ? try await indexedRewindHead(account: account) : nil

        while !Task.isCancelled {
            let state = try await databaseService.transactionSyncState(accountId: try accountId(account))

            guard let storedHead = state.currentHead else {
                return false
            }

            let currentHead = state.ascendingCursor == nil ? min(storedHead, rewindHead ?? storedHead) : storedHead
            rewindHead = nil

            if let head, state.ascendingCursor == nil, currentHead >= head {
                break
            }

            let page: BlockchainTransactionPage

            do {
                page = try await forwardHistory(
                    account: account,
                    client: client,
                    request: BlockchainTransactionHistoryRequest(
                        cursor: state.ascendingCursor,
                        direction: .ascending,
                        lowerBound: currentHead + 1,
                        upperBound: head
                    )
                )
            } catch let error where state.ascendingCursor != nil && !(error is CancellationError) {
                // A cursor written by another source (or app version) can't be
                // resumed. `currentHead` hasn't moved, so restart the range.
                printError("\(account.name): discarding forward cursor: \(error)")
                var resetState = state
                resetState.ascendingCursor = nil
                try await databaseService.saveTransactionSyncState(resetState)
                continue
            }

            try await commit(page, account: account, client: client, track: .ascending, updatesBalances: false)
            touched += page.transactions

            if page.nextCursor == state.ascendingCursor, !page.reachedBoundary {
                try await Task.sleep(for: .seconds(1))
            }

            if page.reachedBoundary {
                break
            }
        }

        await refreshBalances(account: account, transactions: touched)
        return true
    }

    /// Forward pages come from the account's indexed history source when one
    /// applies (public nodes can't filter token events by recipient), falling
    /// back to the node itself.
    func forwardHistory(
        account: Account,
        client: any BlockchainClientProtocol,
        request: BlockchainTransactionHistoryRequest
    ) async throws -> BlockchainTransactionPage {
        guard account.rpcURLOverride == nil,
              let source = transactionHistorySources.first(where: { $0.providesForwardHistory && $0.supports(account) })
        else {
            return try await nodeForwardHistory(account: account, client: client, request: request)
        }

        do {
            let page = try await source.transactionHistory(account: account, request: request)
            logForward(account: account, source: "\(type(of: source))", request: request, page: page)

            return page
        } catch let error where request.cursor == nil && !(error is CancellationError) {
            printError("\(account.name): indexed forward history failed, scanning the node instead: \(error)")
            let page = try await nodeForwardHistory(account: account, client: client, request: request)
            logForward(account: account, source: "node (fallback)", request: request, page: page)

            return page
        }
    }

    func logForward(
        account: Account,
        source: String,
        request: BlockchainTransactionHistoryRequest,
        page: BlockchainTransactionPage
    ) {
        guard !page.transactions.isEmpty else {
            return
        }

        let range = "\(request.lowerBound.map(String.init) ?? "-")...\(request.upperBound.map(String.init) ?? "tip")"

        printDebug(
            "\(account.name): forward \(source) \(range): \(page.transactions.count) txs, head \(page.head.map(String.init) ?? "-")"
        )
    }

    /// The newest stored transaction's block, when forward history comes from an indexer
    /// (cheap to re-query; writes are idempotent).
    func indexedRewindHead(account: Account) async throws -> UInt64? {
        guard account.rpcURLOverride == nil,
              transactionHistorySources.contains(where: { $0.providesForwardHistory && $0.supports(account) })
        else {
            return nil
        }

        return try await databaseService.latestTransactionBlockHeight(accountId: try accountId(account))
    }

    func nodeForwardHistory(
        account: Account,
        client: any BlockchainClientProtocol,
        request: BlockchainTransactionHistoryRequest
    ) async throws -> BlockchainTransactionPage {
        guard case .evm = account.blockchain else {
            return try await client.transactionHistory(account.address, request: request)
        }

        let addresses = try await databaseService.fetchTokens(account: account).compactMap(\.address)
        return try await client.transactionHistory(
            account.address,
            request: BlockchainTransactionHistoryRequest(
                cursor: request.cursor,
                direction: request.direction,
                lowerBound: request.lowerBound,
                upperBound: request.upperBound,
                limit: request.limit,
                assetHints: addresses
            )
        )
    }

    func transactionHistory(
        account: Account,
        client: any BlockchainClientProtocol,
        request: BlockchainTransactionHistoryRequest
    ) async throws -> BlockchainTransactionPage {
        if account.rpcURLOverride == nil,
           let source = transactionHistorySources.first(where: { $0.supports(account) }) {
            let page: BlockchainTransactionPage

            do {
                page = try await source.transactionHistory(account: account, request: request)
            } catch {
                printError("\(account.name): \(type(of: source)) history failed: \(error)")
                throw error
            }

            guard page.head == nil, page.reachedBoundary, case .evm = account.blockchain else {
                return page
            }

            return BlockchainTransactionPage(
                transactions: page.transactions,
                nextCursor: page.nextCursor,
                reachedBoundary: true,
                head: try await nodeHead(account: account, client: client)
            )
        }

        return try await client.transactionHistory(account.address, request: request)
    }

    func commit(
        _ page: BlockchainTransactionPage,
        account: Account,
        client: any BlockchainClientProtocol,
        track: Track,
        updatesBalances: Bool
    ) async throws {
        try Task.checkCancellation()
        try await processTokenTransfers(page.transactions, account: account, client: client)

        let id = try accountId(account)
        let storedState = try await databaseService.transactionSyncState(accountId: id)
        var state = storedState

        switch track {
        case .descending:
            if state.initialBackfillHead == nil {
                state.initialBackfillHead = page.head
            }

            state.descendingCursor = page.nextCursor
            state.backfillComplete = page.reachedBoundary
        case .ascending:
            // A cursor only resumes an unfinished range. Some sources (Sui)
            // return one on the boundary page too; keeping it would pin every
            // later scan to this range's upper bound.
            state.ascendingCursor = page.reachedBoundary ? nil : page.nextCursor
        }

        // A descending page's head is the backfill's fixed upper bound. An
        // ascending page's head is the end of its range, which only counts as
        // scanned once the range's last page is in.
        if let head = page.head, track == .descending || page.reachedBoundary {
            state.currentHead = max(state.currentHead ?? 0, head)
        }

        state.lastError = nil

        guard !page.transactions.isEmpty || state != storedState else {
            return
        }

        // One save() covers both the transaction rows and the sync cursor —
        // a backfill page used to cost two separate write transactions (and
        // two main-thread @Query merges) for this.
        try await databaseService.saveTransactions(page.transactions, for: account, syncState: state)
        try Task.checkCancellation()

        if updatesBalances {
            await enqueueBalanceUpdates(for: page.transactions, account: account)
        }

        // Approvals come from the account's own transactions; a new one may grant or revoke.
        if track == .ascending, account.blockchain.supportsApprovals,
           page.transactions.contains(where: { $0.sender?.caseInsensitiveCompare(account.address) == .orderedSame }) {
            AccountRefresh.enqueueApprovals(account)
        }
    }

    func recordFailure(_ error: any Swift.Error, account: Account) async {
        guard !Task.isCancelled else {
            return
        }

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
        guard !Task.isCancelled, !transactions.isEmpty else {
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
            try Task.checkCancellation()
            try await databaseService.linkTransactionTokens(for: account)
            let tokens = try await databaseService.fetchTokens(account: account)

            for token in tokens {
                try Task.checkCancellation()
                await balancesService.enqueueBalanceUpdate(
                    account: account,
                    tokenAddress: token.address,
                    blockchain: account.blockchain
                )
            }
        } catch is CancellationError {
            return
        } catch {
            printError("\(account.name): \(error)")
        }
    }

    func enqueueBalanceUpdates(for transactions: [BlockchainTransaction], account: Account) async {
        for tokenAddress in Self.balanceRefreshTokens(for: transactions) {
            guard !Task.isCancelled else {
                return
            }

            await balancesService.enqueueBalanceUpdate(
                account: account,
                tokenAddress: tokenAddress,
                blockchain: account.blockchain
            )
        }
    }

    func accountId(_ account: Account) throws -> PersistentIdentifier {
        guard let id = account.id else {
            throw ReefrError.invalidData
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
        client: any BlockchainClientProtocol
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
        client: any BlockchainClientProtocol
    ) async throws {
        let tokenAddresses = Set(tokenEffects.compactMap(\.assetIdentifier))

        guard !tokenAddresses.isEmpty else {
            return
        }

        for tokenAddress in tokenAddresses {
            try Task.checkCancellation()
            guard try await databaseService.fetchToken(
                tokenAddress: tokenAddress,
                blockchain: account.blockchain
            ) == nil else {
                continue
            }

            let resolved: Token

            do {
                resolved = try await token(
                    address: tokenAddress,
                    effects: tokenEffects,
                    blockchain: account.blockchain,
                    client: client
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch where Self.isPermanentTokenFailure(error) {
                // A contract that can't describe itself (non-standard, spam or a non-contract
                // address) must not stall the page that mentions it. Its transfers are kept and
                // the token is retried when one is next committed. A transient failure (timeout,
                // quota) propagates, so the page itself is retried.
                printError("\(account.name): skipping token \(tokenAddress): \(error)")
                continue
            }

            try Task.checkCancellation()
            try await databaseService.insertToken(resolved, blockchain: account.blockchain)
        }
    }

    func token(
        address: String,
        effects: [TokenTransfer],
        blockchain: Blockchain,
        client: any BlockchainClientProtocol
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

extension TransactionSyncService {
    /// Whether a token-metadata read failed because of the contract rather than the connection.
    static func isPermanentTokenFailure(_ error: any Error) -> Bool {
        switch error {
        case BlockchainClientError.decodingFailed:
            true
        case let BlockchainClientError.rpcError(_, message):
            message.localizedCaseInsensitiveContains("revert")
        default:
            false
        }
    }

    /// Backfills the ERC-20 transfers of an account whose history backfill finished before it
    /// included them (ADR-065). Resumable, and it never touches the sync cursors, so forward
    /// progress is preserved. A failure is logged and retried next session; it must not stop
    /// the account's other tracks.
    func runTokenTransferBackfill(account: Account, client: any BlockchainClientProtocol) async {
        do {
            if try await backfillTokenTransfers(account: account, client: client) {
                await enqueueFullRefresh(account: account)
            }
        } catch is CancellationError {
            return
        } catch {
            printError("\(account.name): token transfer backfill: \(error)")
        }
    }

    /// - Returns: whether this call finished the backfill.
    func backfillTokenTransfers(account: Account, client: any BlockchainClientProtocol) async throws -> Bool {
        let id = try accountId(account)

        while !Task.isCancelled {
            let state = try await databaseService.transactionSyncState(accountId: id)

            guard state.tokenBackfillVersion < 1 else {
                return false
            }

            guard
                account.rpcURLOverride == nil,
                let source = transactionHistorySources.first(where: { $0.supports(account) }),
                let page = try await source.tokenTransferHistory(account: account, cursor: state.tokenBackfillCursor)
            else {
                try await databaseService.saveTokenBackfillProgress(accountId: id, cursor: nil, complete: true)
                return false
            }

            try await paceBackfillWrite()
            try Task.checkCancellation()
            try await processTokenTransfers(page.transactions, account: account, client: client)
            try await databaseService.saveTransactions(page.transactions, for: account)
            try await databaseService.saveTokenBackfillProgress(
                accountId: id,
                cursor: page.nextCursor,
                complete: page.reachedBoundary
            )

            if page.reachedBoundary {
                return true
            }
        }

        return false
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
}

// MARK: - Balance refresh selection

extension TransactionSyncService {
    /// An indexer reports no head for an account without history, which would
    /// stall forward sync forever. The node's tip is the right head then: an
    /// empty range above the tip returns it without fetching any block.
    func nodeHead(account: Account, client: any BlockchainClientProtocol) async throws -> UInt64? {
        try await client.transactionHistory(
            account.address,
            request: BlockchainTransactionHistoryRequest(
                cursor: nil,
                direction: .ascending,
                lowerBound: .max,
                upperBound: nil
            )
        ).head
    }

    /// The assets whose balances `transactions` may have changed (`nil` is
    /// the native asset).
    ///
    /// The native asset is always included once there's any transaction:
    /// fees are paid in it on every chain, and many transactions that move
    /// it don't surface as a transfer effect — a Tron stake
    /// (`FreezeBalanceV2Contract`) or contract call has no effects at all.
    static func balanceRefreshTokens(for transactions: [BlockchainTransaction]) -> Set<String?> {
        guard !transactions.isEmpty else {
            return []
        }

        var tokenAddresses: Set<String?> = [nil]

        for effect in transactions.flatMap(\.effects) where effect.kind == .tokenTransfer {
            tokenAddresses.insert(effect.assetIdentifier)
        }

        return tokenAddresses
    }
}
