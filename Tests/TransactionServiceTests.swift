// Integration test for `TransactionService` against a real, running local
// Anvil node — see AnvilTestSupport.swift for the shared node/deployer/
// mock-ERC-20 setup.
//
// Funds a `.local` sender account with native ETH and mock USDC, syncs
// balances through `BalancesService`, then drives a full USDC transfer
// through `TransactionService` (estimate → build → sign → send) to a
// watch-only recipient, and asserts both native (gas-adjusted) and ERC-20
// balances end up correct on both accounts.

import BigInt
import Foundation
import Testing
import WalletKitTesting
@testable import ReefrWallet

@Suite(.timeLimit(.minutes(1)))
struct TransactionServiceTests {
    @Test
    func transferERC20UpdatesSenderAndRecipientBalances() async throws {
        let fixture = try await TransactionFixture.make()
        defer { fixture.node.stop() }

        try await fixture.assertInitialBalancesAreCorrect()

        let receipt = try await fixture.transferMockUSDC(amount: BigUInt(50_000_000)) // 50 USDC
        #expect(receipt.status == "0x1")

        try await fixture.assertFinalBalancesAreCorrect(transferred: BigUInt(50_000_000), receipt: receipt)
    }
}

// MARK: - Fixture

/// Stands up an Anvil node with a `.local` sender account (funded with
/// native ETH + mock USDC) and a watch-only recipient, using
/// `BlockchainClientProvider` directly as an independent, on-chain oracle
/// to cross-check what `BalancesService`/`TransactionService` report.
private struct TransactionFixture {
    let node: EthereumNode
    let client: AnyBlockchainClient
    let databaseService: DatabaseService
    let balancesService: BalancesService
    let feeEstimationService: FeeEstimationService
    let transactionService: TransactionService
    let blockchain: Blockchain
    let sender: ReefrWallet.Account
    let recipient: ReefrWallet.Account
    let mockUSDCAddress: EthereumAddress
    let secondTokenAddress: EthereumAddress
    let senderNativeAmount: BigUInt
    let senderUSDCAmount: BigUInt
    let recipientSecondTokenAmount: BigUInt

    // swiftlint:disable:next function_body_length
    static func make() async throws -> TransactionFixture {
        let node = try await startAnvilNode()
        let blockchain = Blockchain.evm(.custom(node.chainId))

        let databaseService = try makeDatabaseService()
        let accountService = AccountService(databaseService: databaseService)
        let balancesService = BalancesService(databaseService: databaseService)
        let feeEstimationService = FeeEstimationService()
        let transactionService = TransactionService(databaseService: databaseService)

        let deployer = try await makeFundedDeployer(node: node, blockchain: blockchain)
        let mockUSDCAddress = try await deployMockUSDC(deployer: deployer)
        // A second, distinct mock ERC-20 — only the recipient holds this one,
        // and only it (never USDC) is funded there, so the recipient has a
        // non-zero balance in a token other than the one being transferred.
        let secondTokenAddress = try await deployMockUSDC(deployer: deployer)

        // Sender: `.local` keystore, so it can actually sign.
        let senderKeyStore = try await makeLocalKeyStore(
            databaseService: databaseService,
            name: "Anvil Transaction Test Sender Key Store"
        )

        let sender = try await accountService.makeAccount(
            blockchain,
            keyStore: senderKeyStore,
            rpcURLOverride: node.endpoint
        )

        // Recipient: watch-only, only ever receives — never signs.
        let recipientAddress = try EthereumAddress(publicKey: randomEthereumPrivateKey().publicKey)
        let recipientKeyStore = try await makeWatchOnlyKeyStore(
            databaseService: databaseService,
            name: "Anvil Transaction Test Recipient Key Store"
        )

        let recipient = try await accountService.makeAccount(
            blockchain,
            keyStore: recipientKeyStore,
            rpcURLOverride: node.endpoint,
            watchOnlyAddress: recipientAddress.checksummed
        )

        let senderAddress = try EthereumAddress(string: sender.address)
        let senderNativeAmount = BigUInt(5_000_000_000_000_000_000)
        let senderUSDCAmount = BigUInt(200_000_000) // 200 USDC
        let recipientSecondTokenAmount = BigUInt(75_000_000) // 75 of the second token

        try await fundWallet(
            deployer: deployer,
            wallet: senderAddress,
            mockUSDCAddress: mockUSDCAddress,
            native: senderNativeAmount,
            usdc: senderUSDCAmount
        )

        try await mintMockUSDC(
            deployer: deployer,
            mockUSDCAddress: secondTokenAddress,
            wallet: recipientAddress,
            amount: recipientSecondTokenAmount
        )

        try await registerMockUSDCToken(
            databaseService: databaseService,
            blockchain: blockchain,
            mockUSDCAddress: mockUSDCAddress
        )

        try await databaseService.insertToken(
            Token(
                address: secondTokenAddress.checksummed,
                blockchain: blockchain,
                decimalsCount: 6,
                imageURL: nil,
                isHidden: false,
                isIncludedInBalance: true,
                isNativeToken: false,
                name: "Mock Second Token",
                symbol: "MOCK2",
                usdPrice: nil
            ),
            blockchain: blockchain
        )

        try await databaseService.saveTransactions(
            [
                BlockchainTransaction(
                    identifier: "0xsender-token-candidate",
                    status: .confirmed,
                    effects: [
                        BlockchainTransactionEffect(
                            index: 0,
                            kind: .tokenTransfer,
                            assetIdentifier: mockUSDCAddress.checksummed,
                            amount: "1"
                        )
                    ]
                )
            ],
            for: sender
        )
        try await databaseService.saveTransactions(
            [
                BlockchainTransaction(
                    identifier: "0xrecipient-token-candidate",
                    status: .confirmed,
                    effects: [
                        BlockchainTransactionEffect(
                            index: 0,
                            kind: .tokenTransfer,
                            assetIdentifier: secondTokenAddress.checksummed,
                            amount: "1"
                        )
                    ]
                )
            ],
            for: recipient
        )

        try await balancesService.updateBalances(sender)
        try await balancesService.updateBalances(recipient)

        // Use BlockchainClientProvider directly as an independent oracle,
        // separate from the DB-backed BalancesService/TransactionService path.
        let client = try await BlockchainClientProvider().getClient(blockchain: blockchain, rpcURL: node.endpoint)

        return TransactionFixture(
            node: node,
            client: client,
            databaseService: databaseService,
            balancesService: balancesService,
            feeEstimationService: feeEstimationService,
            transactionService: transactionService,
            blockchain: blockchain,
            sender: sender,
            recipient: recipient,
            mockUSDCAddress: mockUSDCAddress,
            secondTokenAddress: secondTokenAddress,
            senderNativeAmount: senderNativeAmount,
            senderUSDCAmount: senderUSDCAmount,
            recipientSecondTokenAmount: recipientSecondTokenAmount
        )
    }

    func assertInitialBalancesAreCorrect() async throws {
        let senderId = try #require(sender.id)
        let senderBalances = try await databaseService.fetchBalances(accountId: senderId)
        let senderNative = try #require(senderBalances.first { $0.token.isNativeToken })
        let senderUSDC = try #require(senderBalances.first { $0.token.address == mockUSDCAddress.checksummed })
        #expect(senderNative.amount == senderNativeAmount)
        #expect(senderUSDC.amount == senderUSDCAmount)

        let recipientId = try #require(recipient.id)
        let recipientBalances = try await databaseService.fetchBalances(accountId: recipientId)
        let recipientNative = try #require(recipientBalances.first { $0.token.isNativeToken })
        let recipientSecondToken = try #require(
            recipientBalances.first { $0.token.address == secondTokenAddress.checksummed }
        )
        #expect(recipientNative.amount == 0)
        #expect(recipientSecondToken.amount == recipientSecondTokenAmount)
        // Zero-balance tokens aren't persisted, so no USDC balance row exists yet.
        #expect(!recipientBalances.contains { $0.token.address == mockUSDCAddress.checksummed })

        // Cross-check against the chain directly.
        #expect(try await client.getNativeBalance(sender.address) == senderNativeAmount)
        #expect(try await client.getBalance(sender.address, token: mockUSDCAddress.checksummed) == senderUSDCAmount)
        #expect(try await client.getNativeBalance(recipient.address) == 0)
        #expect(try await client.getBalance(recipient.address, token: mockUSDCAddress.checksummed) == 0)
        #expect(
            try await client.getBalance(recipient.address, token: secondTokenAddress.checksummed)
                == recipientSecondTokenAmount
        )
    }

    /// Estimates, builds, signs, and sends a mock-USDC transfer from
    /// `sender` to `recipient`, waiting for the receipt.
    func transferMockUSDC(amount: BigUInt) async throws -> TransactionReceipt {
        let usdcToken = Token(
            address: mockUSDCAddress.checksummed,
            blockchain: blockchain,
            decimalsCount: 6,
            imageURL: nil,
            isHidden: false,
            isIncludedInBalance: true,
            isNativeToken: false,
            name: "Mock USDC",
            symbol: "USDC",
            usdPrice: nil
        )

        let decimalAmount = "50"

        let fees = try await feeEstimationService.estimateFees(
            token: usdcToken,
            decimalAmount: decimalAmount,
            recipient: recipient.address,
            account: sender
        )

        let unsignedTx = try await transactionService.makeTransaction(
            token: usdcToken,
            decimalAmount: decimalAmount,
            recipient: recipient.address,
            account: sender,
            fees: fees
        )

        let signature = try await transactionService.signTransaction(unsignedTx, account: sender)
        let hash = try await transactionService.sendTransaction(unsignedTx, signature, account: sender)

        return try await node.waitForReceipt(hash)
    }

    func assertFinalBalancesAreCorrect(transferred: BigUInt, receipt: TransactionReceipt) async throws {
        let gasFee = hexQuantity(receipt.gasUsed) * hexQuantity(receipt.effectiveGasPrice ?? "0x0")

        // A real recipient learns this asset through transaction synchronization
        // before its account-scoped balance refresh is queued.
        try await databaseService.saveTransactions(
            [
                BlockchainTransaction(
                    identifier: "0xrecipient-usdc-after-transfer",
                    status: .confirmed,
                    effects: [
                        BlockchainTransactionEffect(
                            index: 0,
                            kind: .tokenTransfer,
                            assetIdentifier: mockUSDCAddress.checksummed,
                            amount: transferred.description
                        )
                    ]
                )
            ],
            for: recipient
        )

        try await balancesService.updateBalances(sender)
        try await balancesService.updateBalances(recipient)

        let senderId = try #require(sender.id)
        let senderBalances = try await databaseService.fetchBalances(accountId: senderId)
        let senderNative = try #require(senderBalances.first { $0.token.isNativeToken })
        let senderUSDC = try #require(senderBalances.first { $0.token.address == mockUSDCAddress.checksummed })
        #expect(senderNative.amount == senderNativeAmount - gasFee)
        #expect(senderUSDC.amount == senderUSDCAmount - transferred)

        let recipientId = try #require(recipient.id)
        let recipientBalances = try await databaseService.fetchBalances(accountId: recipientId)
        let recipientNative = try #require(recipientBalances.first { $0.token.isNativeToken })
        let recipientUSDC = try #require(recipientBalances.first { $0.token.address == mockUSDCAddress.checksummed })
        #expect(recipientNative.amount == 0)
        #expect(recipientUSDC.amount == transferred)

        // Cross-check against the chain directly.
        #expect(try await client.getNativeBalance(sender.address) == senderNativeAmount - gasFee)
        #expect(try await client.getBalance(
            sender.address, token: mockUSDCAddress.checksummed
        ) == senderUSDCAmount - transferred)
        #expect(try await client.getBalance(recipient.address, token: mockUSDCAddress.checksummed) == transferred)
    }
}
