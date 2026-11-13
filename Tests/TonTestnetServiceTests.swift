// Drives a Gram transfer between two accounts of one seed on the public TON testnet through the app's own
// services (AccountService → BalancesService → FeeEstimationService → TransactionService → TonSendService).
//
// Opt-in: runs when `REEFR_TESTNET_MNEMONIC` is set (see `SepoliaBalanceSyncTests`). Accounts are
// m/44'/607'/0' (sender, needs about 0.3 testnet GRAM from a faucet) and /1' (recipient). The amount sent is
// returned at the end, so only fees are spent.

import BigInt
import Foundation
import Testing
import WalletKit
@testable import ReefrWallet

@Suite(
    .serialized,
    .timeLimit(.minutes(5)),
    .enabled(if: ProcessInfo.processInfo.environment["REEFR_TESTNET_MNEMONIC"] != nil)
)

struct TonTestnetServiceTests {
    private static let amount = BigUInt(50_000_000)
    private static let minimumBalance = BigUInt(250_000_000)
    /// Left behind by the return leg: the recipient's compute fee plus the return transfer's own fees.
    private static let returnReserve = BigUInt(20_000_000)

    @Test // swiftlint:disable:next function_body_length
    func gramMovesBetweenTwoAccountsAndTheSecondSendWaitsForTheFirst() async throws {
        let blockchain = Blockchain.ton(.testnet)
        let databaseService = try makeDatabaseService()
        let accountService = AccountService(databaseService: databaseService)
        let balancesService = BalancesService(databaseService: databaseService)
        let transactionService = TransactionService(databaseService: databaseService)

        let phrase = try #require(ProcessInfo.processInfo.environment["REEFR_TESTNET_MNEMONIC"])
        let keyStore = try await makeLocalKeyStore(
            databaseService: databaseService,
            name: "TON Testnet",
            mnemonic: try Mnemonic.fromPhrase(phrase)
        )

        let sender = try await accountService.makeAccount(blockchain, keyStore: keyStore)
        let recipient = try await accountService.makeAccount(blockchain, keyStore: keyStore)
        #expect(sender.address != recipient.address)
        #expect(sender.publicKey != nil)

        func native(_ account: ReefrWallet.Account) async throws -> (token: Token, amount: BigUInt) {
            try await balancesService.updateBalances(account)
            let id = try #require(account.id)
            let balances = try await databaseService.fetchBalances(accountId: id)
            let balance = try #require(balances.first { $0.token.isNativeToken })
            return (balance.token, balance.amount)
        }

        func transfer(
            from source: ReefrWallet.Account,
            to target: ReefrWallet.Account,
            token: Token,
            decimalAmount: String
        ) async throws -> String {
            let fees = try await FeeEstimationService().estimateFees(
                token: token,
                decimalAmount: decimalAmount,
                recipient: target.address,
                account: source
            )

            let request = try await transactionService.makeTransaction(
                token: token,
                decimalAmount: decimalAmount,
                recipient: target.address,
                account: source,
                fees: fees
            )

            let signature = try await transactionService.signTransaction(request, account: source)
            return try await transactionService.sendTransaction(request, signature, account: source)
        }

        func waitUntil(_ what: String, _ condition: () async throws -> Bool) async throws {
            let deadline = ContinuousClock.now.advanced(by: .seconds(120))

            while ContinuousClock.now < deadline {
                if try await condition() {
                    return
                }

                try await Task.sleep(for: .seconds(3))
            }

            Issue.record("Timed out waiting until \(what).")
        }

        let senderStart = try await native(sender)
        try #require(
            senderStart.amount >= Self.minimumBalance,
            "\(sender.address) holds \(senderStart.amount) nanograms; fund it with at least \(Self.minimumBalance)."
        )

        let recipientStart = try await native(recipient).amount
        let hash = try await transfer(from: sender, to: recipient, token: senderStart.token, decimalAmount: "0.05")
        let senderId = try #require(sender.id)

        // The signed message is stored before it can be confirmed, under the identifier history will report.
        let stored = try await databaseService.fetchBroadcastTransactions(accountId: senderId)
        #expect(stored.contains { $0.identifier == hash })

        // Another send from the same wallet is refused while the first may still be processed. A fast
        // testnet block can settle it first, in which case the new send is rightly allowed.
        do {
            _ = try await transactionService.makeTransaction(
                token: senderStart.token,
                decimalAmount: "0.01",
                recipient: recipient.address,
                account: sender
            )

            let history = try await TonClient(network: .testnet).transactionHistory(
                try TonAddress(string: sender.address),
                request: BlockchainTransactionHistoryRequest(direction: .descending, limit: 10)
            )

            let settled = history.transactions.contains { $0.identifier == hash }
            #expect(settled, "A second send was allowed while the first was unsettled.")
        } catch {
            #expect(error is TonSendError)
        }

        try await waitUntil("the recipient is credited") { try await native(recipient).amount > recipientStart }
        let credited = try await native(recipient).amount - recipientStart
        #expect(credited <= Self.amount)
        #expect(credited > Self.amount - Self.returnReserve)

        // Return the funds; the recipient's first send deploys its wallet.
        let returned = credited - Self.returnReserve
        let decimal = String(format: "%.9f", Double(returned) / 1_000_000_000)
        let senderBeforeReturn = try await native(sender).amount
        _ = try await transfer(from: recipient, to: sender, token: senderStart.token, decimalAmount: decimal)
        try await waitUntil("the sender is credited") { try await native(sender).amount > senderBeforeReturn }
    }
}
