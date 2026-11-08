import Foundation
import SwiftData
import Testing
import WalletKit
@testable import ReefrWallet

// MARK: - Fixtures

let suiOwnerAddress = "0x" + String(repeating: "11", count: 32)

func makeSuiStakingAccount(_ databaseService: DatabaseService) async throws -> ReefrWallet.Account {
    try await makeStakingAccount(databaseService, blockchain: .sui(.mainnet), address: suiOwnerAddress)
}

func suiStakedSui(principal: UInt64 = 10_000_000_000, activation: UInt64 = 5, byte: UInt8 = 0xBB) -> SuiStakedSui {
    SuiStakedSui(
        objectId: Data(repeating: byte, count: 32).hexEncodedForTests,
        version: 9,
        digest: Base58.encode(Data(repeating: 0xB1, count: 32)),
        poolId: "0x" + String(repeating: "02", count: 32),
        activationEpoch: activation,
        principal: principal
    )
}

func suiPosition(
    _ stake: SuiStakedSui = suiStakedSui(),
    status: SuiStakeStatus = .earning,
    reward: UInt64? = 1_000_000
) -> SuiStakePosition {
    SuiStakePosition(
        stake: stake,
        status: status,
        validatorAddress: "0x" + String(repeating: "22", count: 32),
        validatorName: "Mysten-1",
        poolState: .active,
        estimatedReward: reward
    )
}

func suiRead(epoch: UInt64 = 100, positions: [SuiStakePosition] = []) -> SuiStakingRead {
    SuiStakingRead(
        epoch: epoch,
        positions: positions,
        validators: [],
        epochStartTimestampMs: 1_800_000_000_000,
        epochDurationMs: 86_400_000
    )
}

/// A withdrawal of `stake`, as preparation would return it: valid through epoch 101.
func suiPrepared(stake: SuiStakedSui = suiStakedSui(), digestByte: UInt8 = 0xD1) throws -> SuiPreparedStaking {
    let owner = try SuiAddress(rawBytes: Data(repeating: 0x11, count: 32))
    let gas = SuiObjectReference(
        objectId: Data(repeating: 0xAA, count: 32), version: 7, digest: Data(repeating: 0xA1, count: 32)
    )

    let transaction = try SuiStakingTransactions.withdraw(
        stakedSui: try stake.reference(),
        envelope: SuiStakingEnvelope(
            sender: owner, gasPayment: [gas], gasPrice: 1_000, gasBudget: 5_000_000, expirationEpoch: 101
        )
    )

    return SuiPreparedStaking(
        action: .unstake(stake),
        chainId: "chain",
        digest: Data(repeating: digestByte, count: 32),
        expirationEpoch: 101,
        gasBudget: 5_000_000,
        inputs: [SuiInputRef(gas), SuiInputRef(try stake.reference())],
        leftForGas: 1_000_000,
        netFee: 1_000_000,
        startCheckpoint: 5_000,
        transaction: transaction
    )
}

extension Data {
    var hexEncodedForTests: String {
        "0x" + map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Scripted source

/// A ``SuiStakingSource`` whose answers the test scripts, recording what it was asked.
final class FakeSuiStakingSource: SuiStakingSource, @unchecked Sendable {
    struct Failure: Error {}

    private let lock = NSLock()
    private var broadcastResult: SuiBroadcastResult = .accepted
    private var broadcastFlags: [Bool] = []
    private var preparation: Result<SuiPreparedStaking, any Error> = .failure(Failure())
    private var readResult: Result<SuiStakingRead, any Error> = .success(suiRead())
    private var clearFailures = 0
    private var database: DatabaseService?
    private var discardedDigests: [String] = []
    private var recordedDigests: [String] = []
    private var resolutions: [SuiSubmissionResolution] = [.unresolved(.stillValid)]
    private var resolveCount = 0

    /// The store whose claim and history rows a successful ``clearNonExecuted(digest:account:)`` removes.
    func use(_ database: DatabaseService) {
        lock.withLock { self.database = database }
    }

    /// Makes the next `count` clears fail, as a failed save would.
    func failNextClears(_ count: Int) {
        lock.withLock { clearFailures = count }
    }

    func answerBroadcast(with result: SuiBroadcastResult) {
        lock.withLock { broadcastResult = result }
    }

    func answerPrepare(with result: Result<SuiPreparedStaking, any Error>) {
        lock.withLock { preparation = result }
    }

    func answerRead(with result: Result<SuiStakingRead, any Error>) {
        lock.withLock { readResult = result }
    }

    /// Answers resolutions in order; the last one repeats.
    func answerResolve(with list: [SuiSubmissionResolution]) {
        lock.withLock { resolutions = list }
    }

    /// Whether each broadcast was the original send.
    var broadcasts: [Bool] { lock.withLock { broadcastFlags } }
    var discarded: [String] { lock.withLock { discardedDigests } }
    var recorded: [String] { lock.withLock { recordedDigests } }
    var resolveCalls: Int { lock.withLock { resolveCount } }

    func broadcast(
        _ submission: SuiPendingSubmission,
        isOriginalSend: Bool,
        account: ReefrWallet.Account
    ) async -> SuiBroadcastResult {
        lock.withLock {
            broadcastFlags.append(isOriginalSend)
            return broadcastResult
        }
    }

    /// Honors the contract: a failure changes nothing; a success clears the claim and placeholder together.
    func clearNonExecuted(digest: String, account: ReefrWallet.Account) async throws {
        let (failing, database) = lock.withLock { () -> (Bool, DatabaseService?) in
            guard clearFailures == 0 else {
                clearFailures -= 1
                return (true, nil)
            }

            return (false, self.database)
        }

        if failing {
            throw Failure()
        }

        lock.withLock { discardedDigests.append(digest) }
        try await database?.clearNonExecutedSuiSubmission(digest: digest, for: account)
    }

    func liquidBalance(for account: ReefrWallet.Account) async throws -> UInt64 {
        10_000_000_000
    }

    func prepare(_ action: SuiStakingAction, account: ReefrWallet.Account) async throws -> SuiPreparedStaking {
        try lock.withLock { preparation }.get()
    }

    func read(for account: ReefrWallet.Account) async throws -> SuiStakingRead {
        try lock.withLock { readResult }.get()
    }

    func recordBroadcast(digest: String, account: ReefrWallet.Account) async {
        lock.withLock { recordedDigests.append(digest) }
    }

    func resolve(_ submission: SuiPendingSubmission, account: ReefrWallet.Account) async -> SuiSubmissionResolution {
        lock.withLock {
            let index = min(resolveCount, resolutions.count - 1)
            resolveCount += 1
            return resolutions[index]
        }
    }

    func sign(_ prepared: SuiPreparedStaking, account: ReefrWallet.Account) async throws -> Data {
        Data([1, 2, 3])
    }

    func validators(for account: ReefrWallet.Account) async throws -> [SuiValidator] {
        []
    }
}

/// Counts how often the service said a position changed.
actor ChangeCounter {
    private(set) var accounts: [String] = []

    func record(_ account: ReefrWallet.Account) {
        accounts.append(account.address)
    }
}
