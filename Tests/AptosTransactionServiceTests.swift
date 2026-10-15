// Drives a native APT transfer through the app's own services (AccountService
// → BalancesService → FeeEstimationService → TransactionService) against a
// local `aptos node run-localnet`, for both key schemes.

import BigInt
import Foundation
import Testing
import WalletKitTesting
@testable import ReefrWallet

@Suite(.timeLimit(.minutes(3)), .serialized, .localNode)
struct AptosTransactionServiceTests {
    private static let funded: UInt64 = 100_000_000 // 1 APT

    @Test(.serialized, arguments: [Curve.ed25519, .secp256k1])
    func nativeTransferUpdatesBalances(curve: Curve) async throws {
        let node = try await AptosNode.start()
        defer { node.stop() }

        let blockchain = Blockchain.aptos(.testnet)
        let databaseService = try makeDatabaseService()
        let accountService = AccountService(databaseService: databaseService)
        let balancesService = BalancesService(databaseService: databaseService)
        let transactionService = TransactionService(databaseService: databaseService)

        let sender = try await accountService.makeAccount(
            blockchain,
            keyStore: try await makeLocalKeyStore(databaseService: databaseService, name: "Aptos Sender"),
            rpcURLOverride: node.rpcURL,
            signatureScheme: curve
        )
        #expect(sender.signatureScheme == curve)

        let randomBytes = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
        let recipientKey = try PrivateKey(curve: .ed25519, rawBytes: randomBytes)
        let recipient = try await accountService.makeAccount(
            blockchain,
            keyStore: try await makeWatchOnlyKeyStore(databaseService: databaseService, name: "Aptos Recipient"),
            rpcURLOverride: node.rpcURL,
            watchOnlyAddress: try AptosAddress(publicKey: recipientKey.publicKey, curve: .ed25519).string
        )

        try await node.fund(AptosAddress(string: sender.address), octas: Self.funded)
        try await balancesService.updateBalances(sender)

        let senderId = try #require(sender.id)
        let nativeBalance = try #require(try await databaseService.fetchBalances(accountId: senderId).first {
            $0.token.isNativeToken
        })
        #expect(nativeBalance.amount == BigUInt(Self.funded))

        let fees = try await FeeEstimationService().estimateFees(
            token: nativeBalance.token,
            decimalAmount: "0.25",
            recipient: recipient.address,
            account: sender
        )
        #expect(UInt64(try #require(fees.aptosGasUnitPrice)) != nil)
        #expect(UInt64(try #require(fees.nativeFeeReserve)) != nil)

        let transaction = try await transactionService.makeTransaction(
            token: nativeBalance.token,
            decimalAmount: "0.25",
            recipient: recipient.address,
            account: sender,
            fees: fees
        )
        let signature = try await transactionService.signTransaction(transaction, account: sender)
        let hash = try await transactionService.sendTransaction(transaction, signature, account: sender)
        let fee = try #require(try await node.waitForCommit(hash).fee)

        try await balancesService.updateBalances(sender)
        try await balancesService.updateBalances(recipient)

        let senderNative = try #require(try await databaseService.fetchBalances(accountId: senderId).first {
            $0.token.isNativeToken
        })
        #expect(senderNative.amount == BigUInt(Self.funded - 25_000_000 - fee))

        let recipientId = try #require(recipient.id)
        let recipientNative = try #require(try await databaseService.fetchBalances(accountId: recipientId).first {
            $0.token.isNativeToken
        })
        #expect(recipientNative.amount == 25_000_000)
    }

    @Test func watchOnlyAddressesAreStoredInCanonicalForm() async throws {
        let databaseService = try makeDatabaseService()
        let accountService = AccountService(databaseService: databaseService)
        let keyStore = try await makeWatchOnlyKeyStore(databaseService: databaseService, name: "Aptos Watch")

        let account = try await accountService.makeAccount(
            .aptos(.mainnet),
            keyStore: keyStore,
            watchOnlyAddress: "  0x" + String(repeating: "AB", count: 32) + " "
        )

        #expect(account.address == "0x" + String(repeating: "ab", count: 32))
        #expect(!accountService.isValidAddress("0x" + String(repeating: "ab", count: 31), for: .aptos(.mainnet)))
    }
}
