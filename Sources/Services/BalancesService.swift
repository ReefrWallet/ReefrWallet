import BigInt
import Foundation
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
    private lazy var clientProvider = DI.injectOrFail(BlockchainClientProvider.self)
    private let databaseService: DatabaseService

    private var flushTask: Task<Void, Never>?
    private var queuedAccountRefreshes: [PersistentIdentifier: Account] = [:]
    private var queuedTokenUpdates: [BalanceUpdateKey: Account] = [:]

    init(databaseService: DatabaseService? = nil) {
        self.databaseService = databaseService ?? DI.injectOrFail(DatabaseService.self)
    }

    func updateBalances(_ account: Account) async throws {
        let client = try await clientProvider.getClient(
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

            let tokenAddresses = storedTokens
                .filter { !$0.isNativeToken }
                .compactMap(\.address)

            try await updateTokenBalances(
                client: client,
                account: account,
                tokenAddresses: tokenAddresses
            )
        }
    }

    func updateTokenPrices(_ account: Account) async throws {
        let client = try await clientProvider.getClient(
            blockchain: account.blockchain,
            rpcURL: account.rpcURLOverride,
            backend: account.bitcoinBackend
        )

        let tokens = try await databaseService.fetchTokens(account: account)

        let updatedTokens = await withTaskGroup(of: Token?.self) { group in
            for token in tokens {
                group.addTask {
                    do {
                        let usdPrice = try await client.getTokenPrice(token.address)
                        var updatedToken = token
                        updatedToken.usdPrice = usdPrice
                        return updatedToken
                    } catch {
                        printError("\(account.name): \(error)")
                        return nil
                    }
                }
            }

            var results: [Token] = []

            for await updatedToken in group {
                if let updatedToken {
                    results.append(updatedToken)
                }
            }

            return results
        }

        try await databaseService.updateTokenPrices(updatedTokens)
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

        let client = try? await clientProvider.getClient(
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
    func scheduleFlush() {
        flushTask?.cancel()
        flushTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))

            guard !Task.isCancelled else {
                return
            }

            await self?.flushQueue()
        }
    }

    func flushQueue() async {
        let accountRefreshes = queuedAccountRefreshes
        let tokenUpdates = queuedTokenUpdates

        queuedAccountRefreshes.removeAll()
        queuedTokenUpdates.removeAll()

        for account in accountRefreshes.values {
            do {
                try await updateBalances(account)
            } catch {
                printError("\(account.name): \(error)")
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
            }
        }
    }

    func flushTokenUpdates(account: Account, tokenAddresses: [String?]) async throws {
        let client = try await clientProvider.getClient(
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

        let addresses = tokenAddresses.compactMap { $0 }

        guard !addresses.isEmpty else {
            return
        }

        try await updateTokenBalances(client: client, account: account, tokenAddresses: addresses)
    }
}

// MARK: - Private

private extension BalancesService {
    func fetchAllBalances(
        client: AnyBlockchainClient,
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
        client: AnyBlockchainClient,
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

    func updateBalance(account: Account, client: AnyBlockchainClient, tokenAddress: String) async throws {
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

    func updateBalances(account: Account, client: AnyBlockchainClient, tokenAddresses: [String]) async throws {
        let balances = try await client.getBalances(account.address, tokens: tokenAddresses)

        for (tokenAddress, amount) in balances {
            if let storedToken = try await databaseService.fetchToken(
                tokenAddress: tokenAddress,
                blockchain: account.blockchain
            ) {
                if var storedBalance: Balance = try await databaseService.fetchBalance(
                    account: account,
                    tokenAddress: tokenAddress
                ) {
                    // Update stored balance for token
                    storedBalance.amount = amount
                    try await databaseService.saveBalance(storedBalance)
                } else if amount > 0 {
                    // Create new balance for token
                    let balance = Balance(
                        account: account,
                        amount: amount,
                        token: storedToken,
                        usdValue: nil
                    )
                    try await databaseService.saveBalance(balance)
                }
            } else if amount > 0 {
                // Create new token and balance
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
    }

    func updateIndividualBalances(
        client: AnyBlockchainClient,
        account: Account,
        tokenAddresses: [String]
    ) async throws {
        printDebug("Requesting individual balances for \(account.address)")
        var remainingAddresses = tokenAddresses

        await withTaskGroup(of: Void.self) { group in
            while !remainingAddresses.isEmpty {
                guard let tokenAddress = Array(remainingAddresses.prefix(1)).first else {
                    fatalError()
                }

                remainingAddresses.removeFirst(tokenAddresses.count)

                group.addTask {
                    do {
                        try await self.updateBalance(account: account, client: client, tokenAddress: tokenAddress)
                    } catch {
                        printError(error)
                    }
                }
            }
        }
    }

    func updateTokenBalances(
        client: AnyBlockchainClient,
        account: Account,
        tokenAddresses: [String]
    ) async throws {
        guard client.isSupported(.multipleBalances) else {
            try await updateIndividualBalances(client: client, account: account, tokenAddresses: tokenAddresses)
            return
        }

        printDebug("Requesting bulk balances for \(account.address)")
        var remainingAddresses = tokenAddresses

        await withTaskGroup(of: Void.self) { group in
            while !remainingAddresses.isEmpty {
                let batch = Array(remainingAddresses.prefix(20))
                remainingAddresses.removeFirst(batch.count)

                group.addTask {
                    do {
                        try await self.updateBalances(account: account, client: client, tokenAddresses: batch)
                    } catch {
                        printError("\(account.name): \(error)")
                    }
                }
            }

            await group.waitForAll()
        }
    }
}
