import SwiftData
import SwiftUI
import WalletKit

// MARK: - BalancesService

/// Fetches and persists balances. Per-token refresh requests go through a
/// debounced queue (see ``enqueueBalanceUpdate(account:tokenAddress:blockchain:)``)
/// so bursts of transaction-sync activity collapse into one round of RPC
/// calls instead of one per discovered transfer. ``updateBalances(_:)``
/// bypasses the queue for callers (namely the UI) that want an immediate,
/// full resync of every configured/stored token.
actor BalancesService {
    private static let balanceBatchSize = 20
    /// Long enough that a rate-limited or unreachable endpoint isn't hammered.
    private static let flushRetryDelay = Duration.seconds(30)
    private static let maxFlushRetries = 3

    private lazy var clientProvider = DI.injectOrFail(BlockchainClientProvider.self)
    private let databaseService: DatabaseService

    /// The debounce wait. Cancelled and restarted by every enqueue, but only
    /// while it is still sleeping — see ``startFlush()``.
    private var flushTask: Task<Void, Never>?
    /// The flush currently running, if any. Never cancelled, so its
    /// in-flight requests always complete.
    private var activeFlush: Task<Void, Never>?
    /// Consecutive flushes that put something back on the queue.
    private var flushRetries = 0
    private var queuedAccountRefreshes: [PersistentIdentifier: Account] = [:]
    private var queuedTokenUpdates: [BalanceUpdateKey: Account] = [:]

    init(databaseService: DatabaseService? = nil) {
        self.databaseService = databaseService ?? DI.injectOrFail(DatabaseService.self)
    }

    func updateBalances(_ account: Account) async throws {
        let client = try clientProvider.makeClient(
            blockchain: account.blockchain,
            rpcURL: account.rpcURLOverride,
            backend: account.bitcoinBackend
        )

        if client.isSupported(.allBalances) {
            let balances = try await fetchAllBalances(client: client, account: account)
            try await databaseService.updateBalances(account: account, updates: balances)
        } else {
            let storedTokens = try await databaseService.fetchTokens(account: account)

            let nativeBalance = try await fetchNativeBalance(
                client: client,
                account: account,
                storedTokens: storedTokens
            )

            try await databaseService.updateBalances(account: account, updates: [nativeBalance])

            let tokenAddresses = uniqueTokenAddresses(
                storedTokens.filter { !$0.isNativeToken }.compactMap(\.address),
                blockchain: account.blockchain
            )

            try await updateTokenBalances(
                client: client,
                account: account,
                tokenAddresses: tokenAddresses
            )
        }
    }

    func usdValue(accountId: PersistentIdentifier) async throws -> Decimal {
        try await databaseService.usdValue(accountId: accountId)
    }

    func usdValue(keyStoreId: PersistentIdentifier) async throws -> Decimal {
        try await databaseService.usdValue(keyStoreId: keyStoreId)
    }

    /// Enqueues a balance refresh for a single token (`tokenAddress == nil`
    /// means the chain's native asset) instead of updating it inline.
    ///
    /// The queue only drains once a full second passes without a new call here,
    /// and a repeat request for the same account+token replaces whatever was
    /// already queued for it — so a burst of transaction-sync activity
    /// collapses into one round of RPC calls per account instead of one per
    /// discovered transfer. Accounts whose client can fetch every balance in
    /// a single call skip the per-token queue entirely: any of that
    /// account's already-queued token updates are dropped in favor of one
    /// queued full refresh.
    func enqueueBalanceUpdate(account: Account, tokenAddress: String?, blockchain: Blockchain) async {
        guard let accountId = account.id else {
            return
        }

        let client = try? clientProvider.makeClient(
            blockchain: blockchain, rpcURL: account.rpcURLOverride, backend: account.bitcoinBackend
        )

        if client?.isSupported(.allBalances) == true {
            queuedTokenUpdates = queuedTokenUpdates.filter { $0.key.accountId != accountId }

            queuedAccountRefreshes[accountId] = account
        } else {
            queuedTokenUpdates[BalanceUpdateKey(accountId: accountId, tokenAddress: tokenAddress)] = account
        }

        scheduleFlush()
    }
}

// MARK: - Update queue

private struct BalanceUpdateKey: Hashable {
    let accountId: PersistentIdentifier
    let tokenAddress: String?
}

private extension BalancesService {
    func scheduleFlush(after delay: Duration = .seconds(1)) {
        flushTask?.cancel()
        flushTask = Task { [weak self] in
            try? await Task.sleep(for: delay)

            guard !Task.isCancelled else {
                return
            }

            await self?.startFlush()
        }
    }

    /// Hands the queue off to a flush that a later ``scheduleFlush()`` can't
    /// cancel. Cancelling a running flush used to abort its requests
    /// (`AFError.explicitlyCancelled`) after the queue had already been
    /// cleared, silently dropping those updates.
    ///
    /// Flushes run one at a time: a new one waits for the previous to finish
    /// and then takes everything queued in the meantime.
    func startFlush() {
        // Superseded by a newer enqueue while hopping onto the actor.
        guard !Task.isCancelled else {
            return
        }

        flushTask = nil

        let previous = activeFlush
        activeFlush = Task { [weak self] in
            await previous?.value
            await self?.flushQueue()
        }
    }

    /// Drains the queue, putting back whatever failed and retrying it. The
    /// queue is taken before any request runs, so dropping a failure here
    /// would leave the balance stale until the next transaction touched that
    /// asset. ``maxFlushRetries`` keeps a dead endpoint from becoming a poll.
    func flushQueue() async {
        let accountRefreshes = queuedAccountRefreshes
        let tokenUpdates = queuedTokenUpdates

        queuedAccountRefreshes.removeAll()
        queuedTokenUpdates.removeAll()

        var failedRefreshes: [PersistentIdentifier: Account] = [:]
        var failedTokenUpdates: [BalanceUpdateKey: Account] = [:]

        for (accountId, account) in accountRefreshes {
            do {
                try await updateBalances(account)
            } catch {
                printError("\(account.name): \(error)")
                failedRefreshes[accountId] = account
            }
        }

        for (_, keys) in Dictionary(grouping: tokenUpdates.keys, by: \.accountId) {
            guard let account = keys.first.flatMap({ tokenUpdates[$0] }) else {
                continue
            }

            do {
                try await flushTokenUpdates(account: account, tokenAddresses: keys.map(\.tokenAddress))
            } catch {
                printError("\(account.name): \(error)")
                keys.forEach { failedTokenUpdates[$0] = account }
            }
        }

        guard !failedRefreshes.isEmpty || !failedTokenUpdates.isEmpty else {
            flushRetries = 0
            return
        }

        flushRetries += 1

        guard flushRetries <= Self.maxFlushRetries else {
            printError("Giving up on \(failedRefreshes.count + failedTokenUpdates.count) balance update(s)")
            flushRetries = 0
            return
        }

        // Anything enqueued while this flush ran is newer; it wins.
        queuedAccountRefreshes.merge(failedRefreshes) { current, _ in current }
        queuedTokenUpdates.merge(failedTokenUpdates) { current, _ in current }
        scheduleFlush(after: Self.flushRetryDelay)
    }

    func flushTokenUpdates(account: Account, tokenAddresses: [String?]) async throws {
        let client = try clientProvider.makeClient(
            blockchain: account.blockchain,
            rpcURL: account.rpcURLOverride,
            backend: account.bitcoinBackend
        )

        if tokenAddresses.contains(nil) {
            let storedTokens = try await databaseService.fetchTokens(account: account)

            let nativeBalance = try await fetchNativeBalance(
                client: client,
                account: account,
                storedTokens: storedTokens
            )

            try await databaseService.updateBalances(account: account, updates: [nativeBalance])
        }

        let addresses = uniqueTokenAddresses(tokenAddresses.compactMap { $0 }, blockchain: account.blockchain)

        guard !addresses.isEmpty else {
            return
        }

        try await updateTokenBalances(client: client, account: account, tokenAddresses: addresses)
    }
}

// MARK: - Private

private extension BalancesService {
    func fetchAllBalances(
        client: any BlockchainClientProtocol,
        account: Account,
    ) async throws -> [Balance] {
        guard client.isSupported(.allBalances) else {
            throw Error.notSupported
        }

        var balances: [Balance] = []

        for (tokenAddress, amount) in try await client.getAllBalances(account.address) {
            let tokenInfo = try? await client.getTokenInfo(tokenAddress)
            let effectiveAddress = tokenInfo?.isNative == true ? nil : tokenAddress
            let storedToken: Token?

            if let effectiveAddress {
                storedToken = try await databaseService.fetchToken(
                    tokenAddress: effectiveAddress,
                    blockchain: account.blockchain
                )
            } else {
                storedToken = try await databaseService
                    .fetchTokens(blockchain: account.blockchain)
                    .first(where: \.isNativeToken)
            }

            if let token = storedToken {
                balances.append(try await makeBalance(account: account, amount: amount, token: token))
            } else {
                // A node can report a coin that this endpoint cannot describe
                // (for example, a package coin from another localnet). Skip
                // that asset so a valid native balance still reaches the UI.
                guard let tokenInfo else {
                    printDebug("Skipping balance for unsupported token \(tokenAddress) on \(account.name)")
                    continue
                }

                let token = Token(address: effectiveAddress, blockchain: account.blockchain, tokenInfo: tokenInfo)
                balances.append(try await makeBalance(account: account, amount: amount, token: token))
            }
        }

        return balances
    }

    func fetchNativeBalance(
        client: any BlockchainClientProtocol,
        account: Account,
        storedTokens: [Token]
    ) async throws -> Balance {
        let amount = try await client.getNativeBalance(account.address)

        let token: Token
        if let existing = storedTokens.first(where: { $0.isNativeToken }) {
            token = existing
        } else {
            let tokenInfo = try await client.getTokenInfo(nil)
            token = Token(address: nil, blockchain: account.blockchain, tokenInfo: tokenInfo)
        }

        return try await makeBalance(account: account, amount: amount, token: token)
    }

    func makeBalance(account: Account, amount: BigUInt, token: Token) async throws -> Balance {
        let decimalAmount = Decimal(
            sign: .plus,
            exponent: -Int(token.decimalsCount),
            significand: Decimal(amount)
        )

        return Balance(
            account: account,
            amount: amount,
            token: token,
            usdValue: token.usdPrice.map { $0 * decimalAmount }
        )
    }

    func updateBalance(account: Account, client: any BlockchainClientProtocol, tokenAddress: String) async throws {
        let amount = try await client.getBalance(account.address, token: tokenAddress)

        if var storedBalance: Balance = try await databaseService.fetchBalance(
            account: account,
            tokenAddress: tokenAddress
        ) {
            storedBalance.amount = amount
            try await databaseService.saveBalance(storedBalance)
        } else if let storedToken = try await databaseService.fetchToken(
            tokenAddress: tokenAddress,
            blockchain: account.blockchain
        ) {
            let balance = try await makeBalance(account: account, amount: amount, token: storedToken)
            try await databaseService.saveBalance(balance)
        } else {
            let tokenInfo = try await client.getTokenInfo(tokenAddress)
            let token = Token(address: tokenAddress, blockchain: account.blockchain, tokenInfo: tokenInfo)
            try await databaseService.insertToken(token, blockchain: account.blockchain)

            let balance = Balance(
                account: account,
                amount: amount,
                token: token,
                usdValue: nil
            )

            try await databaseService.saveBalance(balance)
        }
    }

    func updateBalances(account: Account, client: any BlockchainClientProtocol, tokenAddresses: [String]) async throws {
        let balances = try await client.getBalances(account.address, tokens: tokenAddresses)
        var errors: [any Swift.Error] = []

        for (tokenAddress, amount) in balances {
            do {
                try await persistBalance(account: account, client: client, tokenAddress: tokenAddress, amount: amount)
            } catch {
                // One undescribable token must not cost the batch its other balances.
                errors.append(error)
            }
        }

        guard errors.isEmpty else {
            throw PartialBalanceUpdateError(errors: errors)
        }
    }

    func persistBalance(
        account: Account,
        client: any BlockchainClientProtocol,
        tokenAddress: String,
        amount: BigUInt
    ) async throws {
        if let storedToken = try await databaseService.fetchToken(
            tokenAddress: tokenAddress,
            blockchain: account.blockchain
        ) {
            if var storedBalance: Balance = try await databaseService.fetchBalance(
                account: account,
                tokenAddress: tokenAddress
            ) {
                storedBalance.amount = amount
                try await databaseService.saveBalance(storedBalance)
            } else if amount > 0 {
                let balance = Balance(account: account, amount: amount, token: storedToken, usdValue: nil)
                try await databaseService.saveBalance(balance)
            }
        } else if amount > 0 {
            let tokenInfo = try await client.getTokenInfo(tokenAddress)
            let token = Token(address: tokenAddress, blockchain: account.blockchain, tokenInfo: tokenInfo)
            try await databaseService.insertToken(token, blockchain: account.blockchain)

            let balance = Balance(account: account, amount: amount, token: token, usdValue: nil)
            try await databaseService.saveBalance(balance)
        }
    }

    func updateIndividualBalances(
        client: any BlockchainClientProtocol,
        account: Account,
        tokenAddresses: [String]
    ) async throws {
        printDebug("Requesting individual balances for \(account.address)")

        let errors = await withTaskGroup(of: (any Swift.Error)?.self) { group in
            for tokenAddress in tokenAddresses {
                group.addTask {
                    do {
                        try await self.updateBalance(account: account, client: client, tokenAddress: tokenAddress)
                        return nil
                    } catch {
                        return error
                    }
                }
            }

            return await group.reduce(into: [any Swift.Error]()) { errors, error in
                if let error {
                    errors.append(error)
                }
            }
        }

        guard errors.isEmpty else {
            throw PartialBalanceUpdateError(errors: errors)
        }
    }

    /// Updates every token's balance in batches. A failed batch doesn't stop the
    /// others; failures are rethrown together once every batch has been tried.
    func updateTokenBalances(
        client: any BlockchainClientProtocol,
        account: Account,
        tokenAddresses: [String]
    ) async throws {
        guard client.isSupported(.multipleBalances) else {
            try await updateIndividualBalances(client: client, account: account, tokenAddresses: tokenAddresses)
            return
        }

        printDebug("Requesting bulk balances for \(account.address)")

        let batches = stride(from: 0, to: tokenAddresses.count, by: Self.balanceBatchSize).map {
            Array(tokenAddresses[$0 ..< min($0 + Self.balanceBatchSize, tokenAddresses.count)])
        }

        let errors = await withTaskGroup(of: (any Swift.Error)?.self) { group in
            for batch in batches {
                group.addTask {
                    do {
                        try await self.updateBalances(account: account, client: client, tokenAddresses: batch)
                        return nil
                    } catch {
                        return error
                    }
                }
            }

            return await group.reduce(into: [any Swift.Error]()) { errors, error in
                if let error {
                    errors.append(error)
                }
            }
        }

        guard errors.isEmpty else {
            printError("\(account.name): \(errors.count) of \(batches.count) balance batches failed: \(errors)")
            throw PartialBalanceUpdateError(errors: errors)
        }
    }

    /// EVM addresses are case-insensitive, and older rows mix lowercase
    /// (indexer/log) and checksummed spellings of the same contract.
    /// Prefers the checksummed spelling, which is what balance results are keyed by.
    func uniqueTokenAddresses(_ addresses: [String], blockchain: Blockchain) -> [String] {
        guard case .evm = blockchain else {
            var seen: Set<String> = []
            return addresses.filter { seen.insert($0).inserted }
        }

        var order: [String] = []
        var preferred: [String: String] = [:]

        for address in addresses {
            let key = address.lowercased()

            if preferred[key] == nil {
                order.append(key)
                preferred[key] = address
            } else if address != key {
                preferred[key] = address
            }
        }

        return order.compactMap { preferred[$0] }
    }
}
