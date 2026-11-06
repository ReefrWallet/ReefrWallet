import Foundation
import SwiftData
import Testing
import WalletKit
@testable import ReefrWallet

// MARK: - Fixtures

func idOf(_ account: ReefrWallet.Account) throws -> PersistentIdentifier {
    guard let id = account.id else {
        throw ReefrError.invalidData
    }

    return id
}

func stakingAddress(_ byte: UInt8) -> TronAddress {
    // swiftlint:disable:next force_try
    try! TronAddress(rawBytes: Data([0x41]) + Data(repeating: byte, count: 20))
}

/// A Tron account in `databaseService`, watch-only.
func makeStakingAccount(
    _ databaseService: DatabaseService,
    blockchain: Blockchain = .tron(.testnet),
    address: String = "TGtcCdz2aV9vvCEtQL5BY8z2BnLi4oJ3sK",
    rpcURL: URL? = nil
) async throws -> ReefrWallet.Account {
    let keyStore = try await makeWatchOnlyKeyStore(databaseService: databaseService)
    let keyStoreId = try #require(keyStore.id)

    var account = ReefrWallet.Account(
        address: address,
        blockchain: blockchain,
        derivationPath: nil,
        keyStoreId: keyStoreId,
        name: "Staking Test",
        rpcURLOverride: rpcURL
    )

    account.id = try await databaseService.insertAccount(account, keyStore: keyStore)
    return account
}

/// 100 TRX staked for bandwidth and 200 for energy, `votes` cast, and the given allowances.
func stakingPosition(
    rewards: UInt64 = 5_000_000,
    votes: [TronRawTransaction.Vote] = [],
    bandwidth: UInt64 = 600,
    energy: UInt64 = 1_000
) -> TronStakingState {
    TronStakingState(
        bandwidth: .init(limit: 600, remaining: bandwidth),
        energy: .init(limit: 2_000, remaining: energy),
        frozen: [
            .init(amount: 100_000_000, resource: .bandwidth),
            .init(amount: 200_000_000, resource: .energy)
        ],
        rewards: rewards,
        unfrozen: [],
        votes: votes,
        weights: .init(energyLimit: 180_000_000_000, energyWeight: 10_000_000_000, netLimit: 1, netWeight: 1),
        withdrawable: 0
    )
}

func resources(bandwidth: UInt64, energy: UInt64) -> TronResourceUsage {
    TronResourceUsage(
        bandwidth: .init(limit: 600, remaining: bandwidth),
        energy: .init(limit: 2_000, remaining: energy)
    )
}

func stakingDate(_ seconds: TimeInterval) -> Date {
    Date(timeIntervalSince1970: 1_800_000_000 + seconds)
}

/// The stored rows, read straight from the container.
func storedStakingRows(_ databaseService: DatabaseService) throws -> [StakingModel] {
    try ModelContext(databaseService.modelContainer).fetch(FetchDescriptor<StakingModel>())
}

// MARK: - Controlled source

/// A ``TronStakingSource`` whose position reads answer when the test says so, so that
/// overlapping requests can finish in any order.
final class ControlledTronStakingSource: TronStakingSource, @unchecked Sendable {
    private let lock = NSLock()
    private var waiters: [CheckedContinuation<TronStakingState, any Error>] = []
    private var automatic: TronStakingState?
    private var stateCount = 0
    private var listCalls = 0
    private var listResult: Result<[TronRepresentative], any Error> = .success([])
    private var listAccounts: [ReefrWallet.Account] = []

    /// Answers every position read at once with `state` instead of waiting.
    func answer(with state: TronStakingState?) {
        lock.withLock { automatic = state }
    }

    func setRepresentatives(_ result: Result<[TronRepresentative], any Error>) {
        lock.withLock { listResult = result }
    }

    var stateRequests: Int { lock.withLock { stateCount } }
    var representativeRequests: Int { lock.withLock { listCalls } }
    var representativeAccounts: [ReefrWallet.Account] { lock.withLock { listAccounts } }

    /// Answers the `index`th unanswered position read.
    func complete(_ index: Int, with state: TronStakingState) {
        lock.withLock { waiters.remove(at: index) }.resume(returning: state)
    }

    func fail(_ index: Int, with error: any Error) {
        lock.withLock { waiters.remove(at: index) }.resume(throwing: error)
    }

    var pendingStateReads: Int { lock.withLock { waiters.count } }

    func representatives(for account: ReefrWallet.Account) async throws -> [TronRepresentative] {
        let result = lock.withLock {
            listCalls += 1
            listAccounts.append(account)
            return listResult
        }

        return try result.get()
    }

    func state(for account: ReefrWallet.Account) async throws -> TronStakingState {
        let immediate = lock.withLock {
            stateCount += 1
            return automatic
        }

        if let immediate {
            return immediate
        }

        return try await withCheckedThrowingContinuation { continuation in
            lock.withLock { waiters.append(continuation) }
        }
    }
}

/// Times that advance by a second on every reading, so later requests always start later.
final class SteppingClock: @unchecked Sendable {
    private let lock = NSLock()
    private var seconds: TimeInterval = 0

    func now() -> Date {
        lock.withLock {
            seconds += 1
            return stakingDate(seconds)
        }
    }

    func jump(by interval: TimeInterval) {
        lock.withLock { seconds += interval }
    }
}

/// Polls until `condition` holds, for up to five seconds.
func eventually(_ condition: @Sendable () -> Bool) async throws {
    for _ in 0..<500 where !condition() {
        try await Task.sleep(for: .milliseconds(10))
    }

    try #require(condition(), "The condition did not hold within five seconds.")
}

// MARK: - Recording refresher

actor RecordingStakingRefresher: StakingRefreshing {
    struct Failure: Error {}

    private(set) var accounts: [String] = []
    private let failing: Bool

    init(failing: Bool = false) {
        self.failing = failing
    }

    func refresh(_ account: ReefrWallet.Account) async throws {
        accounts.append(account.address)

        if failing {
            throw Failure()
        }
    }
}

// MARK: - Recording loader

/// A ``StakingPositionLoading`` for `chains` that only records which accounts it was asked to load.
actor RecordingPositionLoader: StakingPositionLoading {
    private(set) var accounts: [String] = []
    private let chains: @Sendable (Blockchain) -> Bool

    init(supports chains: @escaping @Sendable (Blockchain) -> Bool) {
        self.chains = chains
    }

    nonisolated func supports(_ blockchain: Blockchain) -> Bool {
        chains(blockchain)
    }

    func load(_ account: ReefrWallet.Account, accountId: PersistentIdentifier) async throws {
        accounts.append(account.address)
    }
}
