// Revert Lend plugin runs against a fake vault: loan discovery, collateral rows
// written through the Uniswap V3 pipeline, net totals, the deposit and row
// ownership between the two plugins (ADR-075).

import BigInt
import Foundation
import Testing
import WalletKit
@testable import ReefrWallet

@Suite(.timeLimit(.minutes(1)))
struct RevertLendPluginTests {
    private static let owner = "0x" + String(repeating: "aa", count: 20)
    private static let usdc = BigUInt(1_000_000)

    // MARK: - Fixture

    private struct Fixture {
        let account: ReefrWallet.Account
        let databaseService: DatabaseService
        let plugin: RevertLendPlugin
        let uniswap: UniswapV3Plugin
        let vault = FakeRevertVault()

        init(account: ReefrWallet.Account, databaseService: DatabaseService) {
            self.account = account
            self.databaseService = databaseService
            let vault = vault
            plugin = RevertLendPlugin(
                account: account,
                databaseService: databaseService,
                deployments: [1: FakeRevertVault.deployment],
                readerFactory: { _ in vault },
                tokenSource: FakeUniswapV3TokenSource(),
                uniswapDeployments: [1: FakeUniswapV3Chain.deployment]
            )

            uniswap = UniswapV3Plugin(
                account: account,
                databaseService: databaseService,
                deployments: [1: FakeUniswapV3Chain.deployment],
                readerFactory: { _ in vault.chain },
                requestNFTRefresh: { _ in },
                tokenSource: FakeUniswapV3TokenSource()
            )
        }

        func positions(_ kind: DefiPluginKind) async throws -> [DefiPosition] {
            try await databaseService.fetchDefiPositions(account: account, kind: kind)
        }
    }

    private func makeFixture() async throws -> Fixture {
        let databaseService = try makeDatabaseService()
        let account = try await makeStakingAccount(
            databaseService,
            blockchain: .evm(.ethereum(.mainnet)),
            address: Self.owner
        )

        return Fixture(account: account, databaseService: databaseService)
    }

    private func loan(_ debt: BigUInt, full: BigUInt = 2_000) -> FakeRevertVault.Loan {
        .init(collateralValue: full * Self.usdc * 3 / 4, debt: debt * Self.usdc, fullValue: full * Self.usdc)
    }

    private func decoded(_ position: DefiPosition) throws -> RevertLendPosition {
        try position.payload.decoded()
    }

    // MARK: - Loans

    @Test func aLoanWritesItsCollateralAsAUniswapRowAndItsDebtAsARevertRow() async throws {
        let fixture = try await makeFixture()
        fixture.vault.addLoan(7, loan(500))

        try await fixture.plugin.refresh()

        let collateral = try #require(try await fixture.positions(.uniswapV3).first)
        let payload: UniswapV3Position = try collateral.payload.decoded()
        #expect(collateral.key == "1:7")
        #expect(payload.custodian == .init(kind: .revertLend, vault: FakeRevertVault.vault))
        #expect(collateral.usdValue > 0)

        let lending = try await fixture.positions(.revertLend)
        #expect(lending.map(\.key) == ["loan:1:7"])

        guard case let .loan(loan) = try decoded(try #require(lending.first)) else {
            Issue.record("not a loan")
            return
        }

        #expect(lending.first?.usdValue == -500)
        #expect(loan.health == 3)
        #expect(loan.loanToValue == 0.25)
        #expect(loan.borrowAPR.map { abs(NSDecimalNumber(decimal: $0 - 0.08).doubleValue) < 0.000_01 } == true)
        #expect(loan.token0.symbol == "WETH")
    }

    @Test func theAccountTotalIsPositionMinusDebtPlusDeposit() async throws {
        let fixture = try await makeFixture()
        fixture.vault.addLoan(7, loan(500))
        fixture.vault.setLent(250 * Self.usdc)

        try await fixture.plugin.refresh()

        let collateral = try await fixture.positions(.uniswapV3).reduce(0) { $0 + $1.usdValue }
        let all = try await fixture.positions(.revertLend) + fixture.positions(.uniswapV3)
        #expect(all.reduce(0) { $0 + $1.usdValue } == collateral - 500 + 250)
    }

    @Test func aPositionWithoutDebtHasNoHealth() async throws {
        let fixture = try await makeFixture()
        fixture.vault.addLoan(7, loan(0))

        try await fixture.plugin.refresh()

        guard case let .loan(loan) = try decoded(try #require(try await fixture.positions(.revertLend).first)) else {
            Issue.record("not a loan")
            return
        }

        #expect(loan.health == nil)
    }

    @Test func aClosedLoanRemovesBothRows() async throws {
        let fixture = try await makeFixture()
        fixture.vault.addLoan(7, loan(500))
        fixture.vault.addLoan(8, loan(100))
        try await fixture.plugin.refresh()

        fixture.vault.removeLoan(8, to: "0x" + String(repeating: "cc", count: 20))
        try await fixture.plugin.refresh()

        #expect(try await fixture.positions(.uniswapV3).map(\.key) == ["1:7"])
        #expect(try await fixture.positions(.revertLend).map(\.key) == ["loan:1:7"])
    }

    @Test func aFailedLoanReadKeepsItsRows() async throws {
        let fixture = try await makeFixture()
        fixture.vault.addLoan(7, loan(500))
        try await fixture.plugin.refresh()

        fixture.vault.breakLoanInfo(7)
        try await fixture.plugin.refresh()

        let lending = try await fixture.positions(.revertLend)
        #expect(lending.map(\.key) == ["loan:1:7"])
        #expect(lending.first?.usdValue == -500)
    }

    // MARK: - Deposit

    @Test func aDepositIsShownUntilItIsWithdrawn() async throws {
        let fixture = try await makeFixture()
        fixture.vault.setLent(250 * Self.usdc)
        try await fixture.plugin.refresh()

        let deposit = try #require(try await fixture.positions(.revertLend).first)
        #expect(deposit.key == RevertLendPosition.depositKey)
        #expect(deposit.usdValue == 250)

        guard case let .deposit(payload) = try decoded(deposit) else {
            Issue.record("not a deposit")
            return
        }

        #expect(payload.supplyAPR.map { abs(NSDecimalNumber(decimal: $0 - 0.05).doubleValue) < 0.000_01 } == true)

        fixture.vault.setLent(0)
        try await fixture.plugin.refresh()

        #expect(try await fixture.positions(.revertLend).isEmpty)
    }

    // MARK: - Row ownership

    @Test func uniswapLeavesCollateralRowsToRevert() async throws {
        let fixture = try await makeFixture()
        fixture.vault.addLoan(7, loan(500))
        try await fixture.plugin.refresh()

        // The account's NFT list no longer has #7, or still has it from a stale scan.
        let stored = try await fixture.positions(.uniswapV3)
        let gone = try await fixture.uniswap.outcomes(
            nfts: [], mints: [:], previous: stored, budget: DefiRequestBudget(20), rotation: 0
        )

        let stale = try await fixture.uniswap.outcomes(
            nfts: [nft(7)], mints: [:], previous: stored, budget: DefiRequestBudget(20), rotation: 0
        )

        #expect(gone.isEmpty)
        #expect(stale.isEmpty)
    }

    @Test func aPositionBackInTheWalletBecomesAPlainUniswapRow() async throws {
        let fixture = try await makeFixture()
        fixture.vault.addLoan(7, loan(500))
        try await fixture.plugin.refresh()

        fixture.vault.removeLoan(7, to: Self.owner)
        let outcomes = try await fixture.uniswap.outcomes(
            nfts: [nft(7)],
            mints: [:],
            previous: try await fixture.positions(.uniswapV3),
            budget: DefiRequestBudget(20),
            rotation: 0
        )

        try await fixture.databaseService.saveDefiOutcomes(account: fixture.account, kind: .uniswapV3, outcomes)
        try await fixture.plugin.refresh()

        let collateral = try #require(try await fixture.positions(.uniswapV3).first)
        let payload: UniswapV3Position = try collateral.payload.decoded()
        #expect(payload.custodian == nil)
        #expect(try await fixture.positions(.revertLend).isEmpty)
    }

    // MARK: - Support

    @Test func onlyVaultChainsAreSupported() {
        #expect(RevertLendPlugin.isSupported(.evm(.ethereum(.mainnet))))
        #expect(RevertLendPlugin.isSupported(.evm(.arbitrum(.mainnet))))
        #expect(RevertLendPlugin.isSupported(.evm(.base(.mainnet))))
        #expect(!RevertLendPlugin.isSupported(.evm(.optimism(.mainnet))))
        #expect(!RevertLendPlugin.isSupported(.evm(.ethereum(.sepolia))))
    }

    @Test func perSecondX64RatesBecomeYearlyFractions() {
        let apr = RevertLendPlugin.annualRate(perSecondX64: FakeRevertVault.borrowRateX64)
        #expect(abs(NSDecimalNumber(decimal: apr - 0.08).doubleValue) < 0.000_01)
        #expect(RevertLendPlugin.annualRate(perSecondX64: 0) == 0)
    }

    private func nft(_ tokenId: BigUInt) -> NFT {
        NFT(
            collectionName: nil,
            id: "nft|\(tokenId)",
            imageURL: nil,
            isTransferable: true,
            metadataURI: nil,
            name: nil,
            objectType: nil,
            quantity: 1,
            reference: NFTReference(
                collection: FakeUniswapV3Chain.deployment.positionManager.string.lowercased(),
                isTransferable: true,
                standard: .erc721,
                tokenId: String(tokenId)
            ),
            sendState: nil
        )
    }
}
