//
//  TronStakingService.swift
//  Reefr Wallet
//
//  Created by Andrey Yurkevich on 05.11.26.
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import BigInt
import Foundation
import WalletKit

// MARK: - TronStakingAction

/// What a staking sheet asks the service to sign. Amounts are in SUN.
enum TronStakingAction: Equatable {
    case cancelUnstaking
    case claim
    case stake(sun: UInt64, resource: TronRawTransaction.Resource)
    case unstake(sun: UInt64, resource: TronRawTransaction.Resource)
    case vote([TronRawTransaction.Vote])
    case withdraw

    func contract(owner: TronAddress) -> TronRawTransaction.Contract {
        switch self {
        case .cancelUnstaking:
            .cancelAllUnfreezeV2(owner: owner)
        case .claim:
            .withdrawBalance(owner: owner)
        case let .stake(sun, resource):
            .freezeBalanceV2(owner: owner, amount: sun, resource: resource)
        case let .unstake(sun, resource):
            .unfreezeBalanceV2(owner: owner, amount: sun, resource: resource)
        case let .vote(votes):
            .voteWitness(owner: owner, votes: votes)
        case .withdraw:
            .withdrawExpireUnfreeze(owner: owner)
        }
    }
}

// MARK: - TronStakingTransaction

/// A built, not yet signed, staking transaction.
struct TronStakingTransaction: Equatable {
    let action: TronStakingAction
    /// The estimated cost, when the node could be asked.
    let fee: TronFeeEstimate?
    let raw: TronRawTransaction
    /// The `{txID, raw_data, raw_data_hex}` JSON the signers and broadcast take.
    let unsigned: Data
}

// MARK: - TronStakingError

enum TronStakingError: LocalizedError, Equatable {
    case duplicateRepresentative
    case insufficientBalance
    case insufficientStake
    case insufficientVotePower
    case invalidAmount
    case minimumStake
    case noRewards
    case noUnstaking
    case noVotes
    case noWithdrawable
    case notSupportedOnHardware
    case tooManyRepresentatives
    case tooManyUnstakes
    case transactionFailed(String)
    case unsupportedResource

    var errorDescription: String? {
        switch self {
        case .duplicateRepresentative: String(localized: .tronStakingErrorDuplicateRepresentative)
        case .insufficientBalance: String(localized: .tronStakingErrorInsufficientBalance)
        case .insufficientStake: String(localized: .tronStakingErrorInsufficientStake)
        case .insufficientVotePower: String(localized: .tronStakingErrorInsufficientVotePower)
        case .invalidAmount: String(localized: .tronStakingErrorInvalidAmount)
        case .minimumStake: String(localized: .tronStakingErrorMinimumStake)
        case .noRewards: String(localized: .tronStakingErrorNoRewards)
        case .noUnstaking: String(localized: .tronStakingErrorNoUnstaking)
        case .noVotes: String(localized: .tronStakingErrorNoVotes)
        case .noWithdrawable: String(localized: .tronStakingErrorNoWithdrawable)
        case .notSupportedOnHardware: String(localized: .tronStakingErrorNotSupportedOnHardware)
        case .tooManyRepresentatives:
            String(localized: .tronStakingErrorTooManyRepresentatives(TronStakingService.maxRepresentatives))
        case .tooManyUnstakes:
            String(localized: .tronStakingErrorTooManyUnstakes(TronStakingService.maxPendingUnstakes))
        case let .transactionFailed(reason): String(localized: .tronStakingErrorTransactionFailed(reason))
        case .unsupportedResource: String(localized: .tronStakingErrorUnsupportedResource)
        }
    }
}

// MARK: - TronStakingService

/// Tron Stake 2.0 business logic (ADR-052): reads an account's position,
/// validates and builds stake, unstake, vote, claim, withdraw and cancel
/// transactions on the node, then signs and broadcasts them through
/// ``TransactionService`` (so hardware prompts and history sync behave as for
/// a transfer).
final class TronStakingService: @unchecked Sendable {
    /// Trezor's per-transaction vote limit, applied to every key.
    static let maxRepresentatives = 9
    /// java-tron's limit on unstakes waiting out their 14 days.
    static let maxPendingUnstakes = 32
    /// The smallest stake, 1 TRX.
    static let minimumStakeSun: UInt64 = 1_000_000

    private static let confirmationPollInterval = Duration.seconds(2)
    private static let confirmationPollLimit = 15

    private let injectedBalancesService: BalancesService?
    private let injectedClientProvider: BlockchainClientProvider?
    private let injectedPositionLoader: TronStakingPositionLoader?
    private let injectedStakingStateService: StakingStateService?
    private let injectedTransactionService: TransactionService?

    /// Collaborators default to the DI container's; tests pass their own.
    init(
        balancesService: BalancesService? = nil,
        clientProvider: BlockchainClientProvider? = nil,
        positionLoader: TronStakingPositionLoader? = nil,
        stakingStateService: StakingStateService? = nil,
        transactionService: TransactionService? = nil
    ) {
        injectedBalancesService = balancesService
        injectedClientProvider = clientProvider
        injectedPositionLoader = positionLoader
        injectedStakingStateService = stakingStateService
        injectedTransactionService = transactionService
    }

    private var balancesService: BalancesService {
        injectedBalancesService ?? DI.injectOrFail(BalancesService.self)
    }

    private var clientProvider: BlockchainClientProvider {
        injectedClientProvider ?? DI.injectOrFail(BlockchainClientProvider.self)
    }

    private var positionLoader: TronStakingPositionLoader {
        injectedPositionLoader ?? DI.injectOrFail(TronStakingPositionLoader.self)
    }

    private var stakingStateService: StakingStateService {
        injectedStakingStateService ?? DI.injectOrFail(StakingStateService.self)
    }

    private var transactionService: TransactionService {
        injectedTransactionService ?? DI.injectOrFail(TransactionService.self)
    }

    // MARK: Reading

    /// Whether `account` can stake: a Tron account with a key, or a watch-only one to look at.
    func supports(_ account: Account) -> Bool {
        account.blockchain.supportsStaking
    }

    /// `account`'s liquid TRX, in SUN.
    func availableBalance(for account: Account) async throws -> UInt64 {
        let client = try clientProvider.tronClient(for: account)
        let balance = try await client.getNativeBalance(TronAddress(string: account.address))

        return UInt64(clamping: balance)
    }

    /// The votable representatives, most voted first.
    func representatives(for account: Account) async throws -> [TronRepresentative] {
        try await clientProvider.tronClient(for: account).representatives()
    }

    /// The live position, also stored for the Staking tab.
    func state(for account: Account) async throws -> TronStakingState {
        let startedAt = Date()
        let state = try await clientProvider.tronClient(for: account)
            .stakingState(for: TronAddress(string: account.address))

        await positionLoader.record(state: state, startedAt: startedAt, account: account)
        return state
    }

    // MARK: Writing

    /// Validates `action` against the account's live position and has the
    /// node build it. Nothing is signed.
    ///
    /// - Throws: ``TronStakingError`` when the action isn't allowed.
    func prepare(_ action: TronStakingAction, account: Account) async throws -> TronStakingTransaction {
        let client = try clientProvider.tronClient(for: account)
        let owner = try TronAddress(string: account.address)
        let isHardware = try await transactionService.isHardwareBacked(account)

        if isHardware, case .cancelUnstaking = action {
            throw TronStakingError.notSupportedOnHardware
        }

        let stateStartedAt = Date()
        async let state = client.stakingState(for: owner)
        async let balance = availableBalance(for: account)

        let position = try await state
        await positionLoader.record(state: position, startedAt: stateStartedAt, account: account)

        try Self.validate(action, state: position, balance: try await balance)

        let unsigned = try await client.buildStakingTransaction(action.contract(owner: owner))
        let raw = try TronRawTransaction(envelope: unsigned)

        // Trezor signs its own serialization of the fields; refuse before any prompt
        // when that would differ from what the node built.
        if isHardware, !raw.isTrezorReproducible {
            throw TronStakingError.notSupportedOnHardware
        }

        let feeStartedAt = Date()
        let fee = try? await client.estimateFee(for: raw)

        if let resources = fee?.resources {
            await positionLoader.record(resources: resources, startedAt: feeStartedAt, account: account)
        }

        return TronStakingTransaction(action: action, fee: fee, raw: raw, unsigned: unsigned)
    }

    func sign(_ transaction: TronStakingTransaction, account: Account) async throws -> Data {
        try await transactionService.signTransaction(transaction.unsigned, account: account)
    }

    /// Broadcasts a signed transaction and returns its id.
    func broadcast(_ transaction: TronStakingTransaction, signature: Data, account: Account) async throws -> String {
        try await transactionService.sendTransaction(transaction.unsigned, signature, account: account)
    }

    /// Waits for the node to execute `hash`, then refreshes `account`'s balances (staking,
    /// claiming and withdrawing all change the spendable TRX) and stored position, independently.
    /// Returns quietly if it isn't confirmed after about 30 s.
    ///
    /// - Throws: ``TronStakingError/transactionFailed(_:)`` if the transaction was included and failed.
    func waitForConfirmation(_ hash: String, account: Account) async throws {
        let client = try clientProvider.tronClient(for: account)
        let body = try JSONSerialization.data(withJSONObject: ["value": hash])

        for _ in 0..<Self.confirmationPollLimit {
            let data = try? await client.relay(path: "wallet/gettransactioninfobyid", body: body)
            let info = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }

            if let result = (info?["receipt"] as? [String: Any])?["result"] as? String, result != "SUCCESS" {
                throw TronStakingError.transactionFailed(result)
            }

            if info?["blockNumber"] != nil {
                break
            }

            try await _Concurrency.Task.sleep(for: Self.confirmationPollInterval)
        }

        async let position: Void = refreshPosition(account)
        try? await balancesService.updateBalances(account, includeStaking: false)
        await position
    }

    private func refreshPosition(_ account: Account) async {
        do {
            try await stakingStateService.refreshAfterChange(account)
        } catch {
            printError("\(account.name) staking: \(error)")
        }
    }

    // MARK: Validation

    /// Whether `action` is allowed given the position and liquid `balance` (SUN).
    static func validate(
        _ action: TronStakingAction,
        state: TronStakingState,
        balance: UInt64,
        now: Date = Date()
    ) throws {
        switch action {
        case .cancelUnstaking:
            guard !state.unfrozen.isEmpty else {
                throw TronStakingError.noUnstaking
            }

        case .claim:
            guard state.rewards > 0 else {
                throw TronStakingError.noRewards
            }

        case let .stake(sun, resource):
            try validate(resource: resource)

            guard sun >= minimumStakeSun else {
                throw TronStakingError.minimumStake
            }

            guard sun <= balance else {
                throw TronStakingError.insufficientBalance
            }

        case let .unstake(sun, resource):
            try validate(resource: resource)

            guard sun > 0 else {
                throw TronStakingError.invalidAmount
            }

            guard sun <= state.staked(for: resource) else {
                throw TronStakingError.insufficientStake
            }

            guard state.unfrozen.filter({ $0.expiration > now }).count < maxPendingUnstakes else {
                throw TronStakingError.tooManyUnstakes
            }

        case let .vote(votes):
            try validate(votes: votes, power: state.votePower)

        case .withdraw:
            guard state.withdrawable > 0 else {
                throw TronStakingError.noWithdrawable
            }
        }
    }

    private static func validate(resource: TronRawTransaction.Resource) throws {
        guard resource != .tronPower else {
            throw TronStakingError.unsupportedResource
        }
    }

    private static func validate(votes: [TronRawTransaction.Vote], power: UInt64) throws {
        guard !votes.isEmpty else {
            throw TronStakingError.noVotes
        }

        guard votes.count <= maxRepresentatives else {
            throw TronStakingError.tooManyRepresentatives
        }

        guard Set(votes.map(\.address.string)).count == votes.count else {
            throw TronStakingError.duplicateRepresentative
        }

        guard votes.allSatisfy({ $0.count >= 1 }) else {
            throw TronStakingError.invalidAmount
        }

        guard votes.map(\.count).saturatingSum <= power else {
            throw TronStakingError.insufficientVotePower
        }
    }
}

// MARK: - Saturating sums

extension Sequence where Element == UInt64 {
    /// The sum, or `UInt64.max` instead of an overflow trap (amounts come from text fields).
    var saturatingSum: UInt64 {
        reduce(0) { total, value in
            let (sum, overflow) = total.addingReportingOverflow(value)
            return overflow ? .max : sum
        }
    }
}
