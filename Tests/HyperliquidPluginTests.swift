// Hyperliquid plugin runs, totals and the ADR-073 store migration (ADR-074).

import Foundation
import SwiftData
import Testing
import WalletKit
@testable import ReefrWallet

@Suite(.timeLimit(.minutes(1)))
struct HyperliquidPluginTests {
    private func account(
        _ databaseService: DatabaseService,
        _ fixture: HyperliquidFixture,
        network: EVMBlockchain.HyperEVMNetwork = .mainnet
    ) async throws -> ReefrWallet.Account {
        try await makeStakingAccount(databaseService, blockchain: .evm(.hyperEVM(network)), address: fixture.user)
    }

    /// Refreshes `plugin` and returns its stored position.
    private func run(
        _ plugin: HyperliquidPlugin,
        _ databaseService: DatabaseService
    ) async throws -> HyperliquidPosition? {
        try await plugin.refresh()

        return try await databaseService.fetchDefiPositions(account: plugin.account).first.flatMap {
            try $0.payload.decoded()
        }
    }

    private func plugin(
        _ client: FakeHyperliquidInfoClient,
        metadata: HyperliquidMetadataCache = HyperliquidMetadataCache(),
        _ databaseService: DatabaseService,
        _ account: ReefrWallet.Account
    ) -> HyperliquidPlugin {
        HyperliquidPlugin(account: account, databaseService: databaseService, client: client, metadata: metadata)
    }

    // MARK: - Plugin

    @Test func onlyHyperEVMIsSupported() {
        #expect(!HyperliquidPlugin.isSupported(.evm(.ethereum(.mainnet))))
        #expect(HyperliquidPlugin.isSupported(.evm(.hyperEVM(.testnet))))
        #expect(HyperliquidPlugin.network(.evm(.hyperEVM(.testnet))) == .testnet)
    }

    @Test func aModeSwitchBetweenRefreshesChangesTheFormula() async throws {
        let databaseService = try makeDatabaseService()
        let fixture = try HyperliquidFixture("hyperliquid-unified-isolated")
        let client = FakeHyperliquidInfoClient(fixture.responses)
        let plugin = plugin(client, databaseService, try await account(databaseService, fixture))

        let unified = try #require(try await run(plugin, databaseService))
        client.set(.userAbstraction(user: fixture.user), json: #""default""#)
        let standard = try #require(try await run(plugin, databaseService))

        let perps = try #require(unified.breakdown.perps)
        #expect(unified.mode == "unifiedAccount")
        #expect(standard.mode == "default")
        #expect(standard.portfolioValue.usd == unified.portfolioValue.usd.map { $0 + perps })
        #expect(client.count("userAbstraction") == 2)
    }

    @Test func metadataIsFetchedOnceForTwoAccounts() async throws {
        let databaseService = try makeDatabaseService()
        let fixture = try HyperliquidFixture("hyperliquid-standard-cross")
        let client = FakeHyperliquidInfoClient(fixture.responses)
        let metadata = HyperliquidMetadataCache()

        for _ in 0 ..< 2 {
            let account = try await account(databaseService, fixture)
            _ = try await run(plugin(client, metadata: metadata, databaseService, account), databaseService)
        }

        #expect(client.count("allPerpMetas") == 1)
        #expect(client.count("spotMetaAndAssetCtxs") == 1)
        #expect(client.count("spotClearinghouseState") == 2)
    }

    @Test func aRequestFailureThrowsAndKeepsTheRow() async throws {
        let databaseService = try makeDatabaseService()
        let fixture = try HyperliquidFixture("hyperliquid-standard-cross")
        var responses = fixture.responses
        let account = try await account(databaseService, fixture)

        _ = try await run(plugin(FakeHyperliquidInfoClient(responses), databaseService, account), databaseService)

        responses[.delegatorSummary(user: fixture.user)] = nil
        let failing = plugin(FakeHyperliquidInfoClient(responses), databaseService, account)

        await #expect(throws: FakeHyperliquidInfoClient.Missing.self) {
            try await failing.refresh()
        }

        #expect(try await databaseService.fetchDefiPositions(account: account).count == 1)
    }

    @Test func anEmptiedAccountRemovesItsRow() async throws {
        let databaseService = try makeDatabaseService()
        let fixture = try HyperliquidFixture("hyperliquid-standard-vault")
        let client = FakeHyperliquidInfoClient(fixture.responses)
        let account = try await account(databaseService, fixture)
        let plugin = plugin(client, databaseService, account)

        _ = try await run(plugin, databaseService)
        client.set(.userVaultEquities(user: fixture.user), json: "[]")
        client.set(.spotClearinghouseState(user: fixture.user), json: #"{"balances":[]}"#)

        #expect(try await run(plugin, databaseService) == nil)
        #expect(try await databaseService.fetchDefiPositions(account: account).isEmpty)
    }

    // MARK: - Totals

    @Test func totalsIncludeMainnetAndIgnoreTestnet() async throws {
        let databaseService = try makeDatabaseService()
        let fixture = try HyperliquidFixture("hyperliquid-standard-cross")
        let keyStore = try await makeWatchOnlyKeyStore(databaseService: databaseService)
        let keyStoreId = try #require(keyStore.id)
        var accounts: [ReefrWallet.Account] = []

        for network in [EVMBlockchain.HyperEVMNetwork.mainnet, .testnet] {
            var account = ReefrWallet.Account(
                address: fixture.user,
                blockchain: .evm(.hyperEVM(network)),
                derivationPath: nil,
                keyStoreId: keyStoreId,
                name: "\(network)",
                rpcURLOverride: nil
            )

            account.id = try await databaseService.insertAccount(account, keyStore: keyStore)
            accounts.append(account)
        }

        let client = FakeHyperliquidInfoClient(fixture.responses)
        let mainnet = try #require(try await run(plugin(client, databaseService, accounts[0]), databaseService))
        _ = try await run(plugin(client, databaseService, accounts[1]), databaseService)

        let value = try #require(mainnet.portfolioValue.usd)
        let total = try await databaseService.usdValue(keyStoreId: keyStoreId)
        let testnet = try await databaseService.usdValue(accountId: try #require(accounts[1].id))

        // The store keeps fewer Decimal digits than the computation.
        #expect(abs(total - value) < Decimal(string: "0.000001")!)
        #expect(testnet == 0)
        #expect(try await databaseService.accountUSDValues()[try #require(accounts[0].id)] == total)
    }

    // MARK: - Migration

    @Test func anADR073StoreOpensWithUnpricedRowsAsZero() async throws {
        let source = try #require(
            Bundle.module.url(forResource: "DefiStore-ADR073", withExtension: "sqlite")
        )

        let url = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).sqlite")
        try FileManager.default.copyItem(at: source, to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let databaseService = try makeDatabaseService(configuration: ModelConfiguration(url: url))
        let accounts = try await databaseService.fetchAllAccounts()
        let account = try #require(accounts.first)
        let positions = try await databaseService.fetchDefiPositions(account: account)
        let byKey = Dictionary(uniqueKeysWithValues: positions.map { ($0.key, $0) })

        #expect(byKey["complete"]?.usdValue == 100)
        #expect(byKey["partial"]?.usdValue == 40)
        #expect(byKey["unpriced"]?.usdValue == 0)
        #expect(try await databaseService.usdValue(accountId: try #require(account.id)) == 140)
    }
}
