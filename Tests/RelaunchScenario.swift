// Shared harness for "balances saved → app closed → transfer received →
// app relaunched" scenarios. Each test supplies a funded two-account world
// on a local node; the harness plays the app's lifecycle with fresh
// `BalancesService`/`TransactionSyncService` instances over one database,
// exactly as a relaunch would.

import BigInt
import Foundation
import Testing
import WalletKit
@testable import ReefrWallet

/// The seed every local-node scenario derives its two accounts from.
let localNodeMnemonic = "test test test test test test test test test test test junk"

/// One app launch: services that live until the app is "closed".
struct AppSession {
    let balancesService: BalancesService
    let syncService: TransactionSyncService

    init(databaseService: DatabaseService) {
        balancesService = BalancesService(databaseService: databaseService)
        syncService = TransactionSyncService(balancesService: balancesService, databaseService: databaseService)
    }

    func launch() async {
        await syncService.startAll()
    }

    /// Stops syncing and lets an in-flight debounced balance flush settle.
    func close(_ accounts: [ReefrWallet.Account]) async {
        for account in accounts {
            await syncService.stop(account)
        }

        try? await Task.sleep(for: .seconds(2))
    }
}

/// A sender and a recipient on one chain, plus the out-of-app operations a
/// scenario needs: transferring between them and reading the chain directly.
struct RelaunchScenario {
    /// `nil` is the native asset; otherwise the stored token identifier.
    let assets: [String?]
    let databaseService: DatabaseService
    let recipient: ReefrWallet.Account
    let sender: ReefrWallet.Account
    /// Sends `amount` of `asset` from `sender` to `recipient`, waits for it to
    /// finalize, and returns the transaction identifier.
    let transfer: (_ asset: String?, _ amount: BigUInt) async throws -> String
    /// Node activity after the transfers, e.g. empty blocks past one scan page.
    var afterTransfers: () async throws -> Void = {}
    /// How long a transfer may take to be picked up by sync. Local nodes
    /// finalize within seconds, so 30 seconds is generous.
    var timeout: Duration = .seconds(30)

    var accounts: [ReefrWallet.Account] {
        [sender, recipient]
    }

    /// Runs the reported scenario, then the manual "Update" fallback:
    ///
    /// 1. Launch: initial balances are saved.
    /// 2. Close; `sender` transfers every asset to `recipient`.
    /// 3. Relaunch: balances and transactions catch up with no user action.
    /// 4. Close; transfer again; `BalancesService.updateBalances` (the sidebar
    ///    "Update" button) alone brings balances up to date.
    ///
    /// Native transfers send `nativeAmount`; token transfers send a random
    /// amount up to the sender's balance (see `transferAmount(of:nativeAmount:reserve:)`).
    func run(nativeAmount: BigUInt) async throws {
        let firstLaunch = AppSession(databaseService: databaseService)
        await firstLaunch.launch()
        try await waitUntilBalancesMatchChain(stage: "initial sync")
        await firstLaunch.close(accounts)

        let staleBalances = try await storedBalances(of: recipient)
        var identifiers: [String] = []

        for asset in assets {
            // Keep one unit back so the second round still has something to send.
            let amount = try await transferAmount(of: asset, nativeAmount: nativeAmount, reserve: 1)
            identifiers.append(try await transfer(asset, amount))
        }

        try await afterTransfers()

        #expect(
            try await storedBalances(of: recipient) == staleBalances,
            "Balances changed while the app was closed — the scenario no longer reproduces a relaunch."
        )

        let relaunch = AppSession(databaseService: databaseService)
        await relaunch.launch()
        try await waitUntilBalancesMatchChain(stage: "relaunch", expectedTransactions: identifiers)
        await relaunch.close(accounts)

        for asset in assets {
            let amount = try await transferAmount(of: asset, nativeAmount: nativeAmount, reserve: 0)
            _ = try await transfer(asset, amount)
        }

        try await afterTransfers()

        let manualUpdate = BalancesService(databaseService: databaseService)

        for account in accounts {
            try await manualUpdate.updateBalances(account)
        }

        for account in accounts {
            for asset in assets {
                let stored = try await storedBalance(of: account, asset: asset)
                let onChain = try await chainBalance(of: account, asset: asset)
                #expect(
                    stored == onChain,
                    "Update: \(account.name) \(asset ?? "native") is \(stored), chain has \(onChain)"
                )
            }
        }
    }
}

// MARK: - Amounts

/// A uniformly random token amount, in base units, in `1...(available - reserve)`.
/// Random amounts keep each transfer's balance change distinct from earlier ones.
func randomTransferAmount(available: BigUInt, reserve: BigUInt = 0) throws -> BigUInt {
    let maximum = available > reserve ? available - reserve : 0
    try #require(maximum >= 1, "Not enough to transfer: \(available) available, \(reserve) reserved.")
    let amount = BigUInt.randomInteger(lessThan: maximum) + 1
    printDebug("Random token transfer amount: \(amount) of \(available) available")
    return amount
}

extension RelaunchScenario {
    /// `nativeAmount` for the native asset; otherwise a random amount up to
    /// the sender's current token balance, keeping `reserve` units back.
    func transferAmount(of asset: String?, nativeAmount: BigUInt, reserve: BigUInt) async throws -> BigUInt {
        guard asset != nil else {
            return nativeAmount
        }

        return try randomTransferAmount(available: try await chainBalance(of: sender, asset: asset), reserve: reserve)
    }
}

// MARK: - Assertions

extension RelaunchScenario {
    func chainBalance(of account: ReefrWallet.Account, asset: String?) async throws -> BigUInt {
        let client = try BlockchainClientProvider().makeClient(
            blockchain: account.blockchain,
            rpcURL: account.rpcURLOverride
        )

        guard let asset else {
            return try await client.getNativeBalance(account.address)
        }

        return try await client.getBalance(account.address, token: asset)
    }

    func storedBalance(of account: ReefrWallet.Account, asset: String?) async throws -> BigUInt {
        try await storedBalances(of: account)[asset.map(normalized)] ?? 0
    }

    func storedBalances(of account: ReefrWallet.Account) async throws -> [String?: BigUInt] {
        let accountId = try #require(account.id)
        let balances = try await databaseService.fetchBalances(accountId: accountId)

        return balances.reduce(into: [:]) { result, balance in
            result[balance.token.isNativeToken ? nil : balance.token.address.map(normalized)] = balance.amount
        }
    }

    /// Polls until every account's stored balances equal the chain's (and,
    /// when given, the recipient holds every expected transaction).
    func waitUntilBalancesMatchChain(stage: String, expectedTransactions: [String] = []) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        var mismatches: [String] = []

        while ContinuousClock.now < deadline {
            mismatches = try await currentMismatches(expectedTransactions: expectedTransactions)

            if mismatches.isEmpty {
                return
            }

            try await Task.sleep(for: .seconds(1))
        }

        var states: [String] = []

        for account in accounts {
            let state = try await databaseService.transactionSyncState(accountId: try #require(account.id))
            let head = state.currentHead.map(String.init) ?? "nil"
            states.append("\(account.name): head=\(head) error=\(state.lastError ?? "none")")
        }

        Issue.record("\(stage): \(mismatches.joined(separator: "; ")). Sync state: \(states.joined(separator: "; "))")
    }

    func currentMismatches(expectedTransactions: [String]) async throws -> [String] {
        var mismatches: [String] = []

        for account in accounts {
            for asset in assets {
                let stored = try await storedBalance(of: account, asset: asset)
                let onChain = try await chainBalance(of: account, asset: asset)

                if stored != onChain {
                    mismatches.append("\(account.name) \(asset ?? "native") stored \(stored) ≠ chain \(onChain)")
                }
            }
        }

        let stored = try await databaseService
            .fetchTransactions(accountId: try #require(recipient.id))
            .map { normalized($0.identifier) }

        for identifier in expectedTransactions where !stored.contains(normalized(identifier)) {
            mismatches.append("\(recipient.name) is missing transaction \(identifier)")
        }

        return mismatches
    }

    /// EVM hex identifiers are case-insensitive; base58 ones are not.
    func normalized(_ identifier: String) -> String {
        identifier.hasPrefix("0x") ? identifier.lowercased() : identifier
    }
}

// MARK: - Accounts

/// Inserts the two scenario accounts (sender = index 0, recipient = index 1).
func insertScenarioAccounts(
    addresses: [String],
    blockchain: Blockchain,
    rpcURL: URL?,
    databaseService: DatabaseService
) async throws -> [ReefrWallet.Account] {
    let keyStore = try await makeWatchOnlyKeyStore(databaseService: databaseService, name: "Relaunch Scenario")
    let keyStoreId = try #require(keyStore.id)
    var accounts: [ReefrWallet.Account] = []

    for (index, address) in addresses.enumerated() {
        var account = ReefrWallet.Account(
            accountIndex: nil,
            address: address,
            blockchain: blockchain,
            derivationPath: nil,
            keyStoreId: keyStoreId,
            name: "\(blockchain) #\(index + 1)",
            rpcURLOverride: rpcURL
        )

        account.id = try await databaseService.insertAccount(account, keyStore: keyStore)
        accounts.append(account)
    }

    return accounts
}

/// Derives the private key at `path` from `mnemonic`.
func derivedPrivateKey(mnemonic: String, path: String, curve: Curve) throws -> PrivateKey {
    try Mnemonic.fromPhrase(mnemonic).toSeed().masterKey(curve: curve).derive(DerivationPath(string: path)).privateKey()
}
