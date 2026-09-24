import Foundation
@testable import ReefrWallet
import SwiftData
import Testing
import WalletKitTesting

/// Live Blockfrost-backed coverage for a funded CIP-1852 mainnet account.
///
/// ``CardanoClient`` reads balances and history per stake account, so the five
/// known `addr1…` payment addresses in ``CardanoMainnetAccount`` all resolve to
/// this one account key.
@Suite(.timeLimit(.minutes(3)), .serialized)
struct CardanoMainnetServiceTests {
    @Test(.enabled(if: CardanoMainnetAccount.isEnabled))
    func derivesTheKnownPaymentAddressesFromTheAccountKey() throws {
        let descriptor = try CardanoMainnetAccount.descriptor()
        let derived = try (0 ..< 20).map { index in
            try descriptor.address(role: 0, index: UInt32(index)).string
        }

        #expect(descriptor.stakeAddress == CardanoMainnetAccount.stakeAddress)

        for address in CardanoMainnetAccount.addresses {
            #expect(
                derived.contains(address),
                "\(address) is not one of the account's first 20 receive addresses."
            )
        }
    }

    @Test(.enabled(if: CardanoMainnetAccount.isEnabled))
    func updateBalancesPersistsAdaAndNativeAssetBalances() async throws {
        let databaseService = try makeDatabaseService()
        let account = try await makeAccount(databaseService: databaseService)
        let accountId = try #require(account.id)
        let balancesService = BalancesService(databaseService: databaseService)

        try await balancesService.updateBalances(account)

        let balances = try await databaseService.fetchBalances(accountId: accountId)
        let adaBalance = try #require(
            balances.first(where: { $0.token.isNativeToken }),
            "No ADA balance was saved for \(CardanoMainnetAccount.stakeAddress)."
        )

        #expect(adaBalance.amount > 0)
        #expect(adaBalance.token.symbol == "ADA")
        // The account also holds a native asset (NIGHT) across its addresses.
        #expect(
            balances.contains(where: { !$0.token.isNativeToken }),
            "No native-asset balances were saved, only ADA."
        )
    }

    @Test(.enabled(if: CardanoMainnetAccount.isEnabled))
    func syncsTransactionHistoryForTheStakeAccount() async throws {
        let databaseService = try makeDatabaseService()
        let account = try await makeAccount(databaseService: databaseService)
        let accountId = try #require(account.id)

        let service = TransactionSyncService(databaseService: databaseService)
        await service.start(account)

        defer {
            Task {
                await service.stop(account)
            }
        }

        let deadline = ContinuousClock.now.advanced(by: .seconds(60))

        while ContinuousClock.now < deadline {
            if !(try await databaseService.fetchTransactions(accountId: accountId)).isEmpty {
                return
            }

            try await Task.sleep(for: .milliseconds(500))
        }

        let transactions = try await databaseService.fetchTransactions(accountId: accountId)
        let syncState = try await databaseService.transactionSyncState(accountId: accountId)

        #expect(
            !transactions.isEmpty,
            """
            No Cardano mainnet transactions were saved for \
            \(CardanoMainnetAccount.stakeAddress). Sync error: \(syncState.lastError ?? "none")
            """
        )
    }
}

private extension CardanoMainnetServiceTests {
    func makeAccount(databaseService: DatabaseService) async throws -> Account {
        let keyStore = try await databaseService.watchOnlyKeyStore()
        let keyStoreId = try #require(keyStore.id)

        var account = Account(
            accountIndex: nil,
            address: try CardanoMainnetAccount.descriptor().string,
            blockchain: CardanoMainnetAccount.blockchain,
            derivationPath: nil,
            keyStoreId: keyStoreId,
            name: "Cardano Mainnet Watch-Only"
        )

        account.id = try await databaseService.insertAccount(account, keyStore: keyStore)
        return account
    }

    func makeDatabaseService() throws -> DatabaseService {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
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
            configurations: configuration
        )

        return DatabaseService(modelContainer: container)
    }
}

/// The funded mainnet account the tests above run against — the CIP-1852
/// account behind the five payment addresses in ``addresses``, all of which
/// share its stake key.
enum CardanoMainnetAccount {
    /// `m/1852'/1815'/0'` account public key (32-byte key + 32-byte chain
    /// code), shared with ``WatchOnlyCardanoAccountUITests`` through
    /// `TestVectors/cardano-mainnet-account.json`.
    static let accountXpub = vector.accountXpub

    /// Role-0 payment addresses known to belong to this account.
    static let addresses = vector.addresses

    static let blockchain = WKBlockchain.cardano(.mainnet)

    static let stakeAddress = vector.stakeAddress

    private static let vector = CardanoMainnetAccountVector.load()

    /// Blockfrost reads are metered, so the live tests only run once a mainnet
    /// project ID is configured the same way the app configures one.
    static var isEnabled: Bool {
        let setting = UserDefaults.standard
            .string(forKey: "BlockfrostMainnetProjectID")?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if let setting, !setting.isEmpty {
            return true
        }

        let environmentValue = ProcessInfo.processInfo
            .environment["BLOCKFROST_MAINNET_PROJECT_ID"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return !(environmentValue ?? "").isEmpty
    }

    static func descriptor() throws -> CardanoAccountDescriptor {
        try CardanoAccountDescriptor(xpub: accountXpub, network: .mainnet)
    }
}

/// `TestVectors/cardano-mainnet-account.json` — the account's key and known
/// addresses, kept out of the test sources so the unit and UI test targets
/// share one copy of them.
struct CardanoMainnetAccountVector: Decodable {
    let accountXpub: String
    let addresses: [String]
    let label: String
    let stakeAddress: String

    static func load() -> Self {
        let url = Bundle.module.url(forResource: "cardano-mainnet-account", withExtension: "json")!
        let data = try! Data(contentsOf: url) // swiftlint:disable:this force_try

        return try! JSONDecoder().decode(Self.self, from: data) // swiftlint:disable:this force_try
    }
}
