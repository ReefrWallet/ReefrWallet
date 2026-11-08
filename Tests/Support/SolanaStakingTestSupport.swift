import Foundation
import SwiftData
import Testing
import WalletKit
@testable import ReefrWallet

// MARK: - Fixtures

let solanaOwner = "14CCvQzQzHCVgZM3j9soPnXuJXh1RmCfwLVUcdfbZVBS"
let solanaOtherWallet = "ETxHeBBcuw9Yu4dGuP3oXrD12V5RECvmi8ogQ9PkjyVF"

func makeSolanaStakingAccount(_ databaseService: DatabaseService) async throws -> ReefrWallet.Account {
    try await makeStakingAccount(databaseService, blockchain: .solana(.devnet), address: solanaOwner)
}

func stakeAccount(
    _ address: String,
    stake: UInt64 = 5_000_000_000,
    lamports: UInt64 = 5_002_282_880,
    activation: UInt64 = 1,
    deactivation: UInt64 = .max,
    voter: String? = "voter",
    staker: String = solanaOwner,
    withdrawer: String = solanaOwner,
    lockupTimestamp: Int64 = 0
) -> SolanaStakeAccount {
    SolanaStakeAccount(
        address: address,
        delegation: voter.map {
            .init(activationEpoch: activation, deactivationEpoch: deactivation, stake: stake, voter: $0)
        },
        lamports: lamports,
        lockup: .init(custodian: "", epoch: 0, unixTimestamp: lockupTimestamp),
        rentExemptReserve: 2_282_880,
        staker: staker,
        withdrawer: withdrawer
    )
}

/// A read at `epoch` with a history that settles every account the tests use.
func solanaRead(
    accounts: [SolanaStakeAccount] = [],
    epoch: UInt64 = 100,
    discovery: SolanaStakeDiscovery = .complete,
    slotDuration: Double? = 0.2
) -> SolanaStakingRead {
    SolanaStakingRead(
        accounts: accounts,
        clock: SolanaClock(epoch: epoch, epochStartTimestamp: 0, slot: epoch * 432_000 + 100, unixTimestamp: 1_000),
        discovery: discovery,
        history: SolanaStakeHistory(entries: [:]),
        newRateEpoch: 0,
        schedule: SolanaEpochSchedule(firstNormalEpoch: 0, firstNormalSlot: 0, slotsPerEpoch: 432_000),
        slotDuration: slotDuration
    )
}

func solanaPrepared(
    action: SolanaStakingAction = .unstake(accounts: ["a"]),
    lastValid: UInt64 = 1_000
) -> SolanaPreparedStaking {
    SolanaPreparedStaking(
        action: action,
        estimate: SolanaFeeEstimate(computeUnitLimit: 1_000, computeUnitPrice: 1, fee: 5_001),
        lastValidBlockHeight: lastValid,
        recentBlockhash: "hash",
        rent: 0,
        slotAtBuild: 1,
        unsigned: Data("unsigned".utf8)
    )
}

func solanaPending(signature: String = "SIG", isPastValidity: Bool = false) -> SolanaPendingSubmission {
    SolanaPendingSubmission(
        action: .unstake(accounts: ["a"]),
        isPastValidity: isPastValidity,
        lastValidBlockHeight: 1_000,
        recentBlockhash: "hash",
        signature: signature,
        slotAtBuild: 1
    )
}

/// The stored Solana details of `account`.
func storedSolanaDetails(
    _ databaseService: DatabaseService,
    _ account: ReefrWallet.Account
) async throws -> SolanaStakingDetails {
    let staking = try await databaseService.fetchStaking(accountId: try idOf(account))

    guard case let .solana(details)? = staking?.details else {
        throw ReefrError.notFound
    }

    return details
}

// MARK: - FakeSolanaStakingSource

final class FakeSolanaStakingSource: SolanaStakingSource, @unchecked Sendable {
    private let lock = NSLock()
    private var values = Values()

    fileprivate struct Values {
        var balance: UInt64 = 100_000_000_000
        var blockHeight: UInt64 = 900
        var broadcastError: (any Error)?
        var broadcasts: [(unsigned: Data, signature: Data)] = []
        var knownSeen: [[String]] = []
        var minimum: UInt64 = 1_000_000_000
        var prepared = solanaPrepared()
        var prepareError: (any Error)?
        var read: Result<SolanaStakingRead, any Error> = .success(solanaRead())
        var reconcile: @Sendable (SolanaPendingSubmission) -> SolanaSubmissionUpdate = { .unresolved($0) }
        var recorded: [String] = []
        var rent: UInt64 = 2_282_880
        var rewards: Result<SolanaStakingRewards?, any Error> = .success(nil)
        var rewardCalls = 0
        var signature = Data(repeating: 7, count: 64)
        var statuses: [SolanaSignatureStatus] = [.confirmed]
        var validators: Result<[SolanaValidator], any Error> = .success([])
    }

    func update(_ change: (inout FakeValues) -> Void) {
        lock.withLock {
            var box = FakeValues(values: values)
            change(&box)
            values = box.values
        }
    }

    /// The settable part of the fake.
    struct FakeValues {
        fileprivate var values: Values

        var blockHeight: UInt64 { get { values.blockHeight } set { values.blockHeight = newValue } }
        var broadcastError: (any Error)? { get { values.broadcastError } set { values.broadcastError = newValue } }
        var prepared: SolanaPreparedStaking { get { values.prepared } set { values.prepared = newValue } }
        var prepareError: (any Error)? { get { values.prepareError } set { values.prepareError = newValue } }
        var read: Result<SolanaStakingRead, any Error> { get { values.read } set { values.read = newValue } }

        var reconcile: @Sendable (SolanaPendingSubmission) -> SolanaSubmissionUpdate {
            get { values.reconcile }
            set { values.reconcile = newValue }
        }

        var rewards: Result<SolanaStakingRewards?, any Error> {
            get { values.rewards }
            set { values.rewards = newValue }
        }

        var statuses: [SolanaSignatureStatus] { get { values.statuses } set { values.statuses = newValue } }
        var validators: Result<[SolanaValidator], any Error> {
            get { values.validators }
            set { values.validators = newValue }
        }
    }

    var broadcasts: [(unsigned: Data, signature: Data)] { lock.withLock { values.broadcasts } }
    var knownSeen: [[String]] { lock.withLock { values.knownSeen } }
    var recorded: [String] { lock.withLock { values.recorded } }
    var rewardCalls: Int { lock.withLock { values.rewardCalls } }

    func availableBalance(for account: ReefrWallet.Account) async throws -> UInt64 {
        lock.withLock { values.balance }
    }

    func blockHeight(for account: ReefrWallet.Account) async throws -> UInt64 {
        lock.withLock { values.blockHeight }
    }

    func broadcast(
        _ prepared: SolanaPreparedStaking,
        signature: Data,
        account: ReefrWallet.Account
    ) async throws -> String {
        try lock.withLock {
            values.broadcasts.append((prepared.unsigned, signature))

            if let error = values.broadcastError {
                throw error
            }

            return "node-signature"
        }
    }

    func minimumDelegation(for account: ReefrWallet.Account) async throws -> UInt64 {
        lock.withLock { values.minimum }
    }

    func prepare(_ action: SolanaStakingAction, account: ReefrWallet.Account) async throws -> SolanaPreparedStaking {
        try lock.withLock {
            if let error = values.prepareError {
                throw error
            }

            return values.prepared
        }
    }

    func read(for account: ReefrWallet.Account, known: [String]) async throws -> SolanaStakingRead {
        try lock.withLock {
            values.knownSeen.append(known)
            return try values.read.get()
        }
    }

    func reconcile(
        _ pending: SolanaPendingSubmission,
        account: ReefrWallet.Account,
        checkpoint: @escaping @Sendable (SolanaPendingSubmission) async -> Void
    ) async -> SolanaSubmissionUpdate {
        let handler = lock.withLock { values.reconcile }
        return handler(pending)
    }

    func recordBroadcast(signature: String, account: ReefrWallet.Account) async {
        lock.withLock { values.recorded.append(signature) }
    }

    func rent(for account: ReefrWallet.Account) async throws -> UInt64 {
        lock.withLock { values.rent }
    }

    func rewards(
        for account: ReefrWallet.Account,
        read: SolanaStakingRead,
        retired: [String]
    ) async throws -> SolanaStakingRewards? {
        try lock.withLock {
            values.rewardCalls += 1
            return try values.rewards.get()
        }
    }

    func sign(_ prepared: SolanaPreparedStaking, account: ReefrWallet.Account) async throws -> Data {
        lock.withLock { values.signature }
    }

    func signatureStatus(_ signature: String, account: ReefrWallet.Account) async throws -> SolanaSignatureStatus {
        lock.withLock {
            values.statuses.count > 1 ? values.statuses.removeFirst() : values.statuses[0]
        }
    }

    func validators(for account: ReefrWallet.Account) async throws -> [SolanaValidator] {
        try lock.withLock { try values.validators.get() }
    }
}

final class CallRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var calls: Int { lock.withLock { count } }

    func record() {
        lock.withLock { count += 1 }
    }
}
