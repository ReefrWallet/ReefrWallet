import BigInt
import Foundation
import SwiftData
import Testing
import WalletKit
@testable import ReefrWallet

// MARK: - Fixtures

let cardanoOwner = "cardano:preprod:test"

func makeCardanoStakingAccount(_ databaseService: DatabaseService) async throws -> ReefrWallet.Account {
    try await makeStakingAccount(databaseService, blockchain: .cardano(.preprod), address: cardanoOwner)
}

func cardanoRead(
    registered: Bool = true,
    poolId: String? = "pool1a",
    drep: CardanoDRep? = .abstain,
    rewards: BigUInt = 5_000_000,
    refund: UInt64? = 2_000_000
) -> CardanoStakingRead {
    CardanoStakingRead(
        controlled: 1_250_000_000,
        drep: drep,
        epoch: CardanoEpochTiming(endTime: Date(timeIntervalSince1970: 1_900_000_000), epoch: 512),
        latestReward: CardanoReward(amount: 1_350_000, epoch: 511),
        poolId: poolId,
        refundDeposit: refund,
        registered: registered,
        rewardsSum: 96_200_000,
        withdrawable: rewards
    )
}

/// A prepared transaction whose body is the smallest the builder accepts: the hash is real.
func cardanoPrepared(ttl: UInt64 = 5_000, byte: UInt8 = 0) -> CardanoPreparedStaking {
    CardanoPreparedStaking(
        deposit: 0,
        netLovelace: -170_000,
        refund: 0,
        unsigned: CardanoUnsignedTransaction(
            fee: "170000",
            inputs: [],
            networkId: 0,
            outputs: [],
            signingPaths: [],
            staking: CardanoStakingSummary(deposit: "0", refund: "0", withdrawal: "0"),
            transactionBody: Data([0xA3, 0x00, 0x80, 0x01, 0x80, 0x02, byte]),
            ttl: ttl
        ),
        withdrawal: 0
    )
}

func storedCardanoDetails(
    _ databaseService: DatabaseService,
    _ account: ReefrWallet.Account
) async throws -> CardanoStakingDetails {
    let staking = try await databaseService.fetchStaking(accountId: try idOf(account))

    guard case let .cardano(details)? = staking?.details else {
        throw ReefrError.notFound
    }

    return details
}

func cardanoWorkflow(
    _ phase: CardanoStakingWorkflow.Phase,
    intent: CardanoStakingWorkflow.Intent = .withdraw,
    drep: CardanoDRep = .abstain
) -> CardanoStakingWorkflow {
    CardanoStakingWorkflow(drep: drep, intent: intent, phase: phase, updatedAt: Date(timeIntervalSince1970: 0))
}

// MARK: - FakeCardanoStakingSource

final class FakeCardanoStakingSource: CardanoStakingSource, @unchecked Sendable {
    private let lock = NSLock()
    private var values = Values()

    fileprivate struct Values {
        var balance: BigUInt = 100_000_000
        var broadcastError: (any Error)?
        var broadcasts: [Data] = []
        var drep: CardanoDRepInfo? = CardanoDRepInfo(drepId: "drep1x", isActive: true, name: "Alice")
        var pool: CardanoPool? = CardanoPool(
            fixedCost: 170_000_000,
            marginCost: 0.02,
            name: "Everstake",
            poolId: "pool1a",
            saturation: 0.5,
            ticker: "EVER"
        )

        var prepareError: (any Error)?
        var prepared = cardanoPrepared()
        var preparedActions: [CardanoStakingAction] = []
        var read: Result<CardanoStakingRead, any Error> = .success(cardanoRead())
        var secondsRemaining: Int64 = 3_600
        var states: [String: CardanoSubmissionState] = [:]
        var defaultState: CardanoSubmissionState = .confirmed
    }

    func update(_ change: (inout Settable) -> Void) {
        lock.withLock {
            var box = Settable(values: values)
            change(&box)
            values = box.values
        }
    }

    /// The settable part of the fake.
    struct Settable {
        fileprivate var values: Values

        var broadcastError: (any Error)? { get { values.broadcastError } set { values.broadcastError = newValue } }
        var defaultState: CardanoSubmissionState { get { values.defaultState } set { values.defaultState = newValue } }
        var drep: CardanoDRepInfo? { get { values.drep } set { values.drep = newValue } }
        var pool: CardanoPool? { get { values.pool } set { values.pool = newValue } }
        var prepared: CardanoPreparedStaking { get { values.prepared } set { values.prepared = newValue } }
        var read: Result<CardanoStakingRead, any Error> { get { values.read } set { values.read = newValue } }
        var secondsRemaining: Int64 { get { values.secondsRemaining } set { values.secondsRemaining = newValue } }
        var states: [String: CardanoSubmissionState] { get { values.states } set { values.states = newValue } }
    }

    var broadcasts: [Data] { lock.withLock { values.broadcasts } }
    var preparedActions: [CardanoStakingAction] { lock.withLock { values.preparedActions } }

    func availableBalance(for account: ReefrWallet.Account) async throws -> BigUInt {
        lock.withLock { values.balance }
    }

    func broadcast(
        _ prepared: CardanoPreparedStaking,
        signed: Data,
        account: ReefrWallet.Account
    ) async throws -> String {
        try lock.withLock {
            values.broadcasts.append(signed)

            if let error = values.broadcastError {
                throw error
            }

            return "node-hash"
        }
    }

    func drep(_ id: String, account: ReefrWallet.Account) async throws -> CardanoDRepInfo? {
        lock.withLock { values.drep }
    }

    func pool(_ id: String, account: ReefrWallet.Account) async throws -> CardanoPool? {
        lock.withLock { values.pool }
    }

    func pools(account: ReefrWallet.Account) async throws -> [CardanoPool] {
        lock.withLock { values.pool.map { [$0] } ?? [] }
    }

    func prepare(
        _ action: CardanoStakingAction,
        read: CardanoStakingRead,
        account: ReefrWallet.Account
    ) async throws -> CardanoPreparedStaking {
        try lock.withLock {
            values.preparedActions.append(action)

            if let error = values.prepareError {
                throw error
            }

            return values.prepared
        }
    }

    func read(for account: ReefrWallet.Account) async throws -> CardanoStakingRead {
        try lock.withLock { try values.read.get() }
    }

    func secondsRemaining(ttl: UInt64, account: ReefrWallet.Account) async throws -> Int64 {
        lock.withLock { values.secondsRemaining }
    }

    func sign(_ prepared: CardanoPreparedStaking, account: ReefrWallet.Account) async throws -> Data {
        Data("signed".utf8)
    }

    func submissionState(
        _ pending: CardanoPendingSubmission,
        account: ReefrWallet.Account
    ) async throws -> CardanoSubmissionState {
        lock.withLock { values.states[pending.hash] ?? values.defaultState }
    }
}
