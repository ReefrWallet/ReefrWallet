// Integration tests for `DatabaseService.deleteAllBalances()` and
// `deleteAllTokens()` against a real, running local Anvil node — see
// AnvilTestSupport.swift for the shared node/deployer/mock-ERC-20 setup.
//
// Deploys a tiny throwaway ERC-20 fresh on the local chain, mints it to two
// watch-only accounts added through `AccountService`, then syncs both
// native and ERC-20 balances through `BalancesService` before exercising
// the two delete-all operations under test.

import BigInt
import Foundation
import Testing
import WalletKitTesting
@testable import ReefrWallet

@Suite(.timeLimit(.minutes(1)))
struct DatabaseServiceDeleteAllTests {
    @Test
    func deleteAllBalancesRemovesBalancesButKeepsTokens() async throws {
        let fixture = try await AnvilBalancesFixture.make()
        defer { fixture.node.stop() }

        try await fixture.assertAccountsWereAdded()
        try await fixture.assertBalancesAreCorrect()

        try await fixture.databaseService.deleteAllBalances()

        for account in fixture.accounts {
            let accountId = try #require(account.id)
            #expect(try await fixture.databaseService.fetchBalances(accountId: accountId).isEmpty)
        }

        let remainingTokens = try await fixture.databaseService.fetchTokens(blockchain: fixture.blockchain)
        #expect(remainingTokens.contains { $0.isNativeToken })
        #expect(remainingTokens.contains { $0.address == fixture.mockUSDCAddress })
    }

    @Test
    func deleteAllTokensRemovesAllTokensAndBalances() async throws {
        let fixture = try await AnvilBalancesFixture.make()
        defer { fixture.node.stop() }

        try await fixture.assertAccountsWereAdded()
        try await fixture.assertBalancesAreCorrect()

        try await fixture.databaseService.deleteAllTokens()

        for account in fixture.accounts {
            let accountId = try #require(account.id)
            #expect(try await fixture.databaseService.fetchBalances(accountId: accountId).isEmpty)
        }

        let remainingTokens = try await fixture.databaseService.fetchTokens(blockchain: fixture.blockchain)
        #expect(!remainingTokens.contains { $0.address == fixture.mockUSDCAddress })
        #expect(remainingTokens.allSatisfy { $0.isNativeToken })
    }
}

// MARK: - Fixture

/// Stands up an Anvil node with two funded watch-only accounts (native ETH +
/// a mock ERC-20), added via `AccountService` and synced via `BalancesService`.
private struct AnvilBalancesFixture {
    struct ExpectedBalance {
        let native: BigUInt
        let usdc: BigUInt
    }

    /// Amounts minted/funded per wallet — arbitrary, just distinct enough
    /// between A and B to catch a mixed-up assignment.
    struct FundingAmounts {
        let nativeA = BigUInt(3_000_000_000_000_000_000)
        let nativeB = BigUInt(7_000_000_000_000_000_000)
        let usdcA = BigUInt(100_000_000) // 100 USDC (6 decimals)
        let usdcB = BigUInt(250_000_000) // 250 USDC (6 decimals)
    }

    let node: AnvilNode
    let databaseService: DatabaseService
    let blockchain: WKBlockchain
    let accounts: [Account]
    let mockUSDCAddress: String
    let expectedBalances: [ExpectedBalance]

    // swiftlint:disable:next function_body_length
    static func make() async throws -> AnvilBalancesFixture {
        let node = try await startAnvilNode()
        let blockchain = WKBlockchain.evm(.custom(node.chainId))

        let databaseService = try makeDatabaseService()
        let accountService = AccountService(databaseService: databaseService)
        let balancesService = BalancesService(databaseService: databaseService)

        let deployer = try await makeFundedDeployer(node: node, blockchain: blockchain)
        let mockUSDCAddress = try await deployMockUSDC(deployer: deployer)

        let walletAAddress = try EthereumAddress(publicKey: randomEthereumPrivateKey().publicKey)
        let walletBAddress = try EthereumAddress(publicKey: randomEthereumPrivateKey().publicKey)
        let amounts = FundingAmounts()

        try await fundWallet(
            deployer: deployer,
            wallet: walletAAddress,
            mockUSDCAddress: mockUSDCAddress,
            native: amounts.nativeA,
            usdc: amounts.usdcA
        )

        try await fundWallet(
            deployer: deployer,
            wallet: walletBAddress,
            mockUSDCAddress: mockUSDCAddress,
            native: amounts.nativeB,
            usdc: amounts.usdcB
        )

        let keyStore = try await makeWatchOnlyKeyStore(
            databaseService: databaseService,
            name: "Anvil Delete-All Test Key Store"
        )

        let accountA = try await accountService.makeAccount(
            blockchain,
            keyStore: keyStore,
            rpcURLOverride: node.endpoint,
            watchOnlyAddress: walletAAddress.checksummed
        )

        let accountB = try await accountService.makeAccount(
            blockchain,
            keyStore: keyStore,
            rpcURLOverride: node.endpoint,
            watchOnlyAddress: walletBAddress.checksummed
        )

        try await registerMockUSDCToken(
            databaseService: databaseService,
            blockchain: blockchain,
            mockUSDCAddress: mockUSDCAddress
        )

        try await balancesService.updateBalances(accountA)
        try await balancesService.updateBalances(accountB)

        return AnvilBalancesFixture(
            node: node,
            databaseService: databaseService,
            blockchain: blockchain,
            accounts: [accountA, accountB],
            mockUSDCAddress: mockUSDCAddress.checksummed,
            expectedBalances: [
                ExpectedBalance(native: amounts.nativeA, usdc: amounts.usdcA),
                ExpectedBalance(native: amounts.nativeB, usdc: amounts.usdcB)
            ]
        )
    }

    func assertAccountsWereAdded() async throws {
        #expect(accounts.count == 2)

        for account in accounts {
            let accountId = try #require(account.id)
            #expect(try await databaseService.fetchAccount(id: accountId) == account)
        }

        let storedAddresses = Set(try await databaseService.fetchAccounts(
            keyStoreId: try #require(accounts.first?.keyStoreId)
        ).map(\.address))
        #expect(storedAddresses == Set(accounts.map(\.address)))
    }

    func assertBalancesAreCorrect() async throws {
        for (account, expected) in zip(accounts, expectedBalances) {
            let accountId = try #require(account.id)
            let balances = try await databaseService.fetchBalances(accountId: accountId)
            #expect(balances.count == 2)

            let native = try #require(balances.first { $0.token.isNativeToken })
            #expect(native.amount == expected.native)

            let usdc = try #require(balances.first { $0.token.address == mockUSDCAddress })
            #expect(usdc.amount == expected.usdc)
        }
    }
}
