import Foundation
@testable import ReefrWallet
import SwiftData
import Testing

/// Reproduces Tron sync issues against a copy of the developer's live store. Skipped where none exists.
@Suite(.serialized, .timeLimit(.minutes(1)))
struct LiveStoreTronSyncTests {
    static let liveStoreDirectory = URL.applicationSupportDirectory.appending(path: "xyz.reefr.wallet")

    /// The developer's live store only exists on macOS.
    static var hasLiveStore: Bool {
#if os(macOS)
        FileManager.default.fileExists(atPath: liveStoreDirectory.appending(path: "keystore.sqlite").path)
#else
        false
#endif
    }

    /// TRC-20 transfer that used to stay "Pending" (no block height).
    private let tokenTransferId = "46c044e06158c0476ffc23f1e45d2a572bd38abf8071e921ea2156c74c43a776"
    /// Swap payout that reaches the account only as an internal TRX transfer.
    private let internalTransferId = "e244162f08c38cc15e492da1869520672ba0097d78bf704991b1fc575073ed58"

    @Test(.enabled(if: hasLiveStore))
    func normalizingStableIdsRemovesDuplicateRows() async throws {
        let databaseService = try copyLiveStore()
        try await databaseService.normalizeTransactionStableIds()

        for account in try await databaseService.fetchAllAccounts() {
            let identifiers = try await databaseService.fetchTransactions(accountId: try #require(account.id))
                .map(\.identifier)
            #expect(Set(identifiers).count == identifiers.count, "\(account.name): duplicate rows")
        }

        // Idempotent: a second pass finds nothing to change.
        try await databaseService.normalizeTransactionStableIds()
    }

    @Test(.enabled(if: hasLiveStore))
    func syncsTronTokenAndInternalTransfersFromLiveStoreCopy() async throws {
        let databaseService = try copyLiveStore()
        try await databaseService.normalizeTransactionStableIds()
        let account = try #require(
            try await databaseService.fetchAllAccounts().first {
                $0.blockchain == .tron(.mainnet) && $0.address == "TMZNJsNex59tEozFeRTLD7sC2ZyENcz69t"
            }
        )

        let accountId = try #require(account.id)

        let service = TransactionSyncService(databaseService: databaseService)
        await service.start(account)

        var transactions: [WalletTransaction] = []
        let deadline = ContinuousClock.now.advanced(by: .seconds(30))

        while ContinuousClock.now < deadline {
            transactions = try await databaseService.fetchTransactions(accountId: accountId)

            if transactions.contains(where: { $0.identifier == internalTransferId }),
               transactions.contains(where: { $0.identifier == tokenTransferId && $0.blockHeight != nil }) {
                break
            }

            try await Task.sleep(for: .milliseconds(500))
        }

        await service.stop(account)

        let syncState = try await databaseService.transactionSyncState(accountId: accountId)
        let identifiers = transactions.map(\.identifier)
        #expect(identifiers.contains(internalTransferId), "Sync error: \(syncState.lastError ?? "none")")
        let pending = transactions.filter { $0.blockHeight == nil }.map(\.identifier)
        #expect(pending.isEmpty, "Still pending: \(pending)")
        #expect(syncState.currentHead != nil)
        #expect(
            Set(identifiers).count == identifiers.count,
            "Duplicate rows: \(transactions.map { "\($0.stableId) h=\(String(describing: $0.blockHeight))" })"
        )
    }

    /// Copies the live store (with its WAL) to a temporary directory; the original is never opened.
    private func copyLiveStore() throws -> DatabaseService {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory.appending(path: "live-store-\(UUID().uuidString)")
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        for name in try fileManager.contentsOfDirectory(atPath: Self.liveStoreDirectory.path)
        where name.hasPrefix("keystore.sqlite") {
            try fileManager.copyItem(
                at: Self.liveStoreDirectory.appending(path: name),
                to: directory.appending(path: name)
            )
        }

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
            configurations: ModelConfiguration(url: directory.appending(path: "keystore.sqlite"))
        )

        return DatabaseService(modelContainer: container)
    }
}
