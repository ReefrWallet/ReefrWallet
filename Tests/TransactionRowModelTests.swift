import Foundation
import SwiftData
import Testing
import WalletKit
@testable import ReefrWallet

@Suite(.timeLimit(.minutes(1)))
struct TransactionRowModelTests {
    static let counterparty = "0x71C7656EC7ab88b098defB751B7401B5f6d8976F"
    static let owner = "0xf39fd6e51aad88f6f4ce6ab8827279cfffb92266"

    @Test(arguments: [
        BlockLabelCase(blockchain: .aptos(.mainnet), confirmed: "Version 7", pending: "Pending"),
        BlockLabelCase(blockchain: .bitcoin(.mainnet), confirmed: "Block #7", pending: "In mempool"),
        BlockLabelCase(blockchain: .evm(.ethereum(.mainnet)), confirmed: "Block #7", pending: "Pending"),
        BlockLabelCase(blockchain: .solana(.mainnet), confirmed: "Slot 7", pending: "Pending"),
        BlockLabelCase(blockchain: .sui(.mainnet), confirmed: "Checkpoint 7", pending: "Pending"),
        BlockLabelCase(blockchain: .tron(.mainnet), confirmed: "Block #7", pending: "Pending")
    ])
    func blockLabelsFollowEachChain(_ testCase: BlockLabelCase) async throws {
        let account = try await makeAccount(blockchain: testCase.blockchain)
        let confirmed = try model(BlockchainTransaction(identifier: "a", blockHeight: 7, status: .confirmed), account)
        let pending = try model(BlockchainTransaction(identifier: "b", status: .unconfirmed), account)

        #expect(confirmed.blockLabel == testCase.confirmed)
        #expect(pending.blockLabel == testCase.pending)
    }

    @Test
    func counterpartyNameWinsOverAddressInSubtitleAndToColumn() async throws {
        let account = try await makeAccount(blockchain: .evm(.ethereum(.mainnet)))
        let row = try model(
            BlockchainTransaction(
                identifier: "0xabc",
                sender: Self.owner,
                recipient: Self.counterparty,
                status: .confirmed,
                counterpartyName: "Circle: USDC Token",
                method: "Approve"
            ),
            account
        )

        #expect(row.subtitle == "Circle: USDC Token")
        #expect(row.toLabel == "Circle: USDC Token")
        #expect(row.fromLabel == account.name)
        #expect(row.method == "Approve")
    }

    @Test
    func evmReceiveIsSignedAndLabelled() async throws {
        let account = try await makeAccount(blockchain: .evm(.ethereum(.mainnet)))
        let row = try model(
            BlockchainTransaction(
                identifier: "0xabc",
                blockHeight: 1,
                sender: Self.counterparty,
                recipient: Self.owner,
                status: .confirmed,
                effects: [
                    BlockchainTransactionEffect(
                        index: 0,
                        kind: .nativeTransfer,
                        amount: "250000000000000000",
                        from: Self.counterparty,
                        to: Self.owner
                    )
                ],
                fee: "21000000000000",
                method: "Transfer"
            ),
            account
        )

        #expect(row.kind == .received)
        #expect(row.direction == .incoming)
        #expect(row.subtitle == "From 0x71C7…976F")
        #expect(row.fromLabel == "0x71C7…976F")
        #expect(row.toLabel == account.name)
        let amount = Decimal(0.25).formatted(.number.precision(.fractionLength(0...6)))
        #expect(row.amountText == "+\(amount) ETH")
        #expect(row.rawAmountText == "\(amount) ETH")
        #expect(row.fee == Decimal(string: "0.000021"))
        #expect(row.feeSymbol == "ETH")
    }

    @Test
    func failedAndPendingStatusesAreFlagged() async throws {
        let account = try await makeAccount(blockchain: .tron(.mainnet))

        #expect(try model(BlockchainTransaction(identifier: "a", status: .failed), account).isFailed)
        #expect(try model(BlockchainTransaction(identifier: "b", status: .reverted), account).isFailed)
        #expect(try model(BlockchainTransaction(identifier: "c", status: .broadcast), account).isPending)
        #expect(try model(BlockchainTransaction(identifier: "d", status: .unconfirmed), account).isPending)
    }

    @Test
    func missingCounterpartyFallsBackToShortHash() async throws {
        let account = try await makeAccount(blockchain: .bitcoin(.mainnet))
        let transaction = BlockchainTransaction(identifier: String(repeating: "f", count: 64), status: .confirmed)
        let row = try model(transaction, account)

        #expect(row.subtitle == "ffffff…ffff")
    }

    @Test
    func multiAssetCountsEffects() async throws {
        let account = try await makeAccount(blockchain: .sui(.mainnet))
        let row = try model(
            BlockchainTransaction(
                identifier: "digest",
                status: .confirmed,
                effects: [
                    BlockchainTransactionEffect(
                        index: 0, kind: .balanceChange, assetIdentifier: "0x2::sui::SUI", amount: "-1"
                    ),
                    BlockchainTransactionEffect(
                        index: 1, kind: .balanceChange, assetIdentifier: "0x5::usdc::USDC", amount: "2"
                    )
                ]
            ),
            account
        )

        #expect(row.kind == .multiAsset)
        #expect(row.title == "2 Assets")
        #expect(row.amountText == "2 Tokens")
    }

    @Test
    func multiAssetCountsNFTsBeforeTokens() async throws {
        let account = try await makeAccount(blockchain: .evm(.ethereum(.mainnet)))
        let collection = "0xBC4CA0EdA7647A8aB7C2061c2E118A18a936f13D"
        let transferTopic = "0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef"
        let nft = { (index: UInt64, tokenId: String) in
            BlockchainTransactionEffect(
                index: index,
                kind: .tokenTransfer,
                assetIdentifier: collection,
                from: Self.counterparty,
                to: Self.owner,
                rawPayload: try? ["topics": [transferTopic, "0x1", "0x2", tokenId]].encoded()
            )
        }

        let row = try model(
            BlockchainTransaction(
                identifier: "0xabc",
                status: .confirmed,
                effects: [
                    nft(0, "0x01"),
                    nft(1, "0x02"),
                    BlockchainTransactionEffect(
                        index: 2,
                        kind: .tokenTransfer,
                        assetIdentifier: "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48",
                        amount: "1000000",
                        from: Self.owner,
                        to: Self.counterparty
                    )
                ]
            ),
            account
        )

        #expect(row.kind == .multiAsset)
        #expect(row.amountText == "2 NFTs, 1 Token")
    }

    @Test
    func schemasDifferPerChain() {
        #expect(TransactionRowPresenters.presenter(for: .solana(.mainnet)).schema.toTitle == "Program")
        #expect(TransactionRowPresenters.presenter(for: .sui(.mainnet)).schema.feeTitle == "Gas (SUI)")
        #expect(TransactionRowPresenters.presenter(for: .cardano(.mainnet)).schema.fromTitle == nil)
        #expect(TransactionRowPresenters.presenter(for: .tron(.mainnet)).schema.showsDirection)
        #expect(TransactionRowPresenters.presenter(for: .evm(.ethereum(.mainnet))).schema.feeTitle == "Fee (ETH)")
    }

    @Test
    func resyncWithoutDetailsKeepsStoredFeeAndMethod() async throws {
        let service = try makeDatabaseService()
        let account = try await makeAccount(blockchain: .evm(.ethereum(.mainnet)), service: service)
        let rich = BlockchainTransaction(
            identifier: "0xabc",
            status: .confirmed,
            counterpartyName: "1inch: Router V6",
            fee: "42",
            method: "Swap"
        )

        try await service.saveTransactions([rich], for: account)
        let poor = BlockchainTransaction(identifier: "0xabc", status: .confirmed)
        try await service.saveTransactions([poor], for: account)

        let accountId = try #require(account.id)
        let stored = try #require(try await service.fetchTransactions(accountId: accountId).first)
        #expect(stored.counterpartyName == "1inch: Router V6")
        #expect(stored.fee == "42")
        #expect(stored.method == "Swap")
    }

    @Test
    func evmMethodNamesAreTitleCased() {
        #expect(EVMMethodName.display("swapExactTokensForTokens(uint256,uint256)", hasValue: false)
            == "Swap Exact Tokens For Tokens")
        #expect(EVMMethodName.display("meta_route", hasValue: false) == "Meta Route")
        #expect(EVMMethodName.display(nil, hasValue: true) == "Transfer")
        #expect(EVMMethodName.display("0xa9059cbb", hasValue: false) == nil)
    }
}

struct BlockLabelCase: Sendable, CustomTestStringConvertible {
    let blockchain: Blockchain
    let confirmed: String
    let pending: String

    var testDescription: String {
        confirmed
    }
}

private extension TransactionRowModelTests {
    func makeAccount(blockchain: Blockchain, service: DatabaseService? = nil) async throws -> ReefrWallet.Account {
        let service = try service ?? makeDatabaseService()
        let keyStore = try await service.watchOnlyKeyStore()
        var account = Account(
            accountIndex: nil,
            address: Self.owner,
            blockchain: blockchain,
            derivationPath: nil,
            keyStoreId: try #require(keyStore.id),
            name: "Main Account"
        )

        account.id = try await service.insertAccount(account, keyStore: keyStore)
        return account
    }

    func makeDatabaseService() throws -> DatabaseService {
        let container = try ModelContainer(
            for: AccountModel.self,
                BalanceModel.self,
                BlockchainModel.self,
                KeyStoreModel.self,
                TokenModel.self,
                SavedAddressModel.self,
                WalletTransactionModel.self,
                WalletTransactionEffectModel.self,
                WalletTransactionSyncStateModel.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )

        return DatabaseService(modelContainer: container)
    }

    func model(_ transaction: BlockchainTransaction, _ account: ReefrWallet.Account) throws -> TransactionRowModel {
        TransactionRowPresenters
            .presenter(for: account.blockchain)
            .makeRowModel(try WalletTransaction(account: account, transaction: transaction), account: account)
    }
}
