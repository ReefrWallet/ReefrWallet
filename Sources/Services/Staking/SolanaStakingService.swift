//
//  SolanaStakingService.swift
//  Reefr Wallet
//
//  Created by Andrey Yurkevich on 06.11.26.
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import Foundation
import SwiftData
import WalletKit

// MARK: - SolanaStakingError

enum SolanaStakingError: LocalizedError, Equatable {
    case amountTooLarge
    case belowMinimum(UInt64)
    case cannotUnstake
    case cannotWithdraw
    case epochRewardsActive
    case expiredBeforeSending
    case insufficientBalance
    case nothingSelected
    case partialNeedsWithdrawAuthority
    case remainderBelowMinimum(UInt64)
    case simulationFailed(String)
    case submissionUnresolved
    case tooManySelected

    var errorDescription: String? {
        switch self {
        case .amountTooLarge:
            String(localized: .solanaStakingErrorAmountTooLarge)
        case let .belowMinimum(lamports):
            String(localized: .solanaStakingErrorBelowMinimum(SolanaStakingFormat.sol(lamports)))
        case .cannotUnstake:
            String(localized: .solanaStakingErrorCannotUnstake)
        case .cannotWithdraw:
            String(localized: .solanaStakingErrorCannotWithdraw)
        case .epochRewardsActive:
            String(localized: .solanaStakingErrorEpochRewardsActive)
        case .expiredBeforeSending:
            String(localized: .solanaStakingOutcomeSignAgainNote)
        case .insufficientBalance:
            String(localized: .solanaStakingErrorInsufficientBalance)
        case .nothingSelected:
            String(localized: .solanaStakingErrorNothingSelected)
        case .partialNeedsWithdrawAuthority:
            String(localized: .solanaStakingNoteFullOnly)
        case let .remainderBelowMinimum(lamports):
            String(localized: .solanaStakingErrorRemainderBelowMinimum(SolanaStakingFormat.sol(lamports)))
        case let .simulationFailed(reason):
            String(localized: .solanaStakingErrorSimulationFailed(reason))
        case .submissionUnresolved:
            String(localized: .solanaStakingNotePaused)
        case .tooManySelected:
            String(localized: .solanaStakingErrorTooManySelected)
        }
    }
}

// MARK: - SolanaStakingOutcome

/// What became of a broadcast, as far as is known when the wait ends.
enum SolanaStakingOutcome: Equatable {
    /// Applied; the fee was charged.
    case confirmed
    /// Landed and failed: staking changes reverted, the fee was charged.
    case failed
    /// Not resolved yet. Staking stays paused, and position refreshes keep checking.
    case submitted(signature: String)
}

// MARK: - SolanaStakingFormat

enum SolanaStakingFormat {
    private static let lamportsPerSol = Decimal(1_000_000_000)

    /// All nine decimals when needed: rent is 0.00228288 SOL.
    static func sol(_ lamports: UInt64) -> String {
        let amount = decimalSol(lamports).formatted(.number.precision(.fractionLength(0...9)))
        return String(localized: .commonAmountWithSymbol(amount, "SOL"))
    }

    static func decimalSol(_ lamports: UInt64) -> Decimal {
        Decimal(lamports) / lamportsPerSol
    }
}

// MARK: - SolanaStakingService

/// Native SOL staking (ADR-054): validates an action against the live position, builds it, signs
/// it, records it, broadcasts those exact bytes and follows what becomes of it.
final class SolanaStakingService: @unchecked Sendable {
    /// Left unstaked by Max, so the user can still pay to unstake and withdraw.
    static let feeReserveLamports: UInt64 = 10_000_000

    private let confirmationPollInterval: Duration
    private let confirmationPollLimit: Int
    private let injectedPositionLoader: SolanaStakingPositionLoader?
    private let injectedSource: (any SolanaStakingSource)?
    private let injectedStakingStateService: StakingStateService?
    private let onChanged: (@Sendable (Account) async -> Void)?

    /// Collaborators default to the DI container's; tests pass their own.
    init(
        positionLoader: SolanaStakingPositionLoader? = nil,
        source: (any SolanaStakingSource)? = nil,
        stakingStateService: StakingStateService? = nil,
        confirmationPollInterval: Duration = .seconds(2),
        confirmationPollLimit: Int = 15,
        onChanged: (@Sendable (Account) async -> Void)? = nil
    ) {
        self.confirmationPollInterval = confirmationPollInterval
        self.confirmationPollLimit = confirmationPollLimit
        injectedPositionLoader = positionLoader
        injectedSource = source
        injectedStakingStateService = stakingStateService
        self.onChanged = onChanged
    }

    private var positionLoader: SolanaStakingPositionLoader {
        injectedPositionLoader ?? DI.injectOrFail(SolanaStakingPositionLoader.self)
    }

    private var source: any SolanaStakingSource {
        injectedSource ?? SolanaNodeStakingSource()
    }

    private var stakingStateService: StakingStateService {
        injectedStakingStateService ?? DI.injectOrFail(StakingStateService.self)
    }

    // MARK: Reading

    /// `account`'s liquid SOL, in lamports.
    func availableBalance(for account: Account) async throws -> UInt64 {
        try await source.availableBalance(for: account)
    }

    func minimumDelegation(for account: Account) async throws -> UInt64 {
        try await source.minimumDelegation(for: account)
    }

    func rent(for account: Account) async throws -> UInt64 {
        try await source.rent(for: account)
    }

    /// The most `balance` can stake, keeping rent and the reserve.
    static func maxStake(balance: UInt64, rent: UInt64) -> UInt64 {
        let kept = rent + feeReserveLamports
        return balance > kept ? balance - kept : 0
    }

    // MARK: Writing

    /// Validates `action` against the account's live position and builds it. Nothing is signed.
    ///
    /// - Throws: ``SolanaStakingError`` when the action isn't allowed or simulation rejects it.
    func prepare(_ action: SolanaStakingAction, account: Account) async throws -> SolanaPreparedStaking {
        guard let accountId = account.id else {
            throw ReefrError.invalidData
        }

        guard try await positionLoader.pendingSubmissions(accountId: accountId).isEmpty else {
            throw SolanaStakingError.submissionUnresolved
        }

        let startedAt = Date()
        let known = try await positionLoader.knownAddresses(accountId: accountId)

        async let read = source.read(for: account, known: known)
        async let balance = source.availableBalance(for: account)
        async let minimum = source.minimumDelegation(for: account)
        async let rent = source.rent(for: account)

        let position = try await read
        try await positionLoader.record(read: position, startedAt: startedAt, account: account)

        try Self.validate(
            action,
            owner: account.address,
            positions: position.positions,
            clock: position.clock,
            balance: try await balance,
            minimum: try await minimum,
            rent: try await rent
        )

        do {
            let live = Self.withLiveAmounts(action, positions: position.positions)
            return try await source.prepare(live, account: account)
        } catch SolanaStakingBuildError.epochRewardsActive {
            throw SolanaStakingError.epochRewardsActive
        } catch let SolanaStakingBuildError.simulationFailed(reason) {
            throw SolanaStakingError.simulationFailed(reason)
        } catch SolanaStakingBuildError.transactionTooLarge {
            throw SolanaStakingError.tooManySelected
        }
    }

    func sign(_ prepared: SolanaPreparedStaking, account: Account) async throws -> Data {
        try await source.sign(prepared, account: account)
    }

    /// Sends exactly what was signed, having first recorded it so its outcome survives a crash.
    ///
    /// - Throws: ``SolanaStakingError/expiredBeforeSending`` if it took too long to sign: nothing
    ///   was sent and it needs a new signature. A node's rejection means it wasn't submitted.
    ///   Any other send failure may still have landed, so it's followed like a success.
    func submit(
        _ prepared: SolanaPreparedStaking,
        signature: Data,
        account: Account
    ) async throws -> SolanaStakingOutcome {
        guard let accountId = account.id else {
            throw ReefrError.invalidData
        }

        guard try await source.blockHeight(for: account) <= prepared.lastValidBlockHeight else {
            throw SolanaStakingError.expiredBeforeSending
        }

        let identifier = SolanaRPCClient.signatureString(signature)

        try await positionLoader.addPending(
            SolanaPendingSubmission(
                action: prepared.action,
                lastValidBlockHeight: prepared.lastValidBlockHeight,
                recentBlockhash: prepared.recentBlockhash,
                signature: identifier,
                slotAtBuild: prepared.slotAtBuild
            ),
            accountId: accountId
        )

        do {
            _ = try await source.broadcast(prepared, signature: signature, account: account)
        } catch let error as BlockchainClientError {
            if case .rpcError = error {
                try await positionLoader.removePending(signature: identifier, accountId: accountId)
                throw error
            }

            await source.recordBroadcast(signature: identifier, account: account)
        } catch {
            await source.recordBroadcast(signature: identifier, account: account)
        }

        return await follow(identifier, account: account, accountId: accountId)
    }

    /// Checks unresolved transactions now.
    func checkAgain(_ account: Account) async throws {
        guard let accountId = account.id else {
            throw ReefrError.invalidData
        }

        await positionLoader.reconcilePending(account, accountId: accountId)
    }

    /// What the latest check of `signature` found, if it has been checked.
    func latestUpdate(for signature: String) async -> SolanaSubmissionUpdate? {
        await positionLoader.latestUpdate(for: signature)
    }

    // MARK: Validation

    /// A withdrawal takes an account's whole balance. A reward paid after the sheet read it would
    /// leave a remainder below rent, which the program refuses, so amounts come from the live read.
    static func withLiveAmounts(
        _ action: SolanaStakingAction,
        positions: [SolanaStakePosition]
    ) -> SolanaStakingAction {
        guard case let .withdraw(withdrawals) = action else {
            return action
        }

        return .withdraw(withdrawals.map { withdrawal in
            let live = positions.first { $0.account.address == withdrawal.address }?.account.lamports
            return .init(address: withdrawal.address, lamports: live ?? withdrawal.lamports)
        })
    }

    /// Whether `action` is allowed given the position, liquid `balance`, and the cluster's
    /// `minimum` delegation and `rent` (lamports).
    static func validate(
        _ action: SolanaStakingAction,
        owner: String,
        positions: [SolanaStakePosition],
        clock: SolanaClock,
        balance: UInt64,
        minimum: UInt64,
        rent: UInt64
    ) throws {
        let byAddress = Dictionary(positions.map { ($0.account.address, $0) }, uniquingKeysWith: { first, _ in first })

        switch action {
        case let .stake(lamports, _):
            guard lamports >= minimum else {
                throw SolanaStakingError.belowMinimum(minimum)
            }

            guard [lamports, rent].saturatingSum <= balance else {
                throw SolanaStakingError.insufficientBalance
            }

        case let .unstake(accounts):
            guard !accounts.isEmpty else {
                throw SolanaStakingError.nothingSelected
            }

            guard accounts.allSatisfy({ byAddress[$0]?.canUnstake(owner: owner) == true }) else {
                throw SolanaStakingError.cannotUnstake
            }

        case let .unstakePartial(account, lamports):
            guard let position = byAddress[account], position.canUnstake(owner: owner) else {
                throw SolanaStakingError.cannotUnstake
            }

            guard position.account.withdrawer == owner else {
                throw SolanaStakingError.partialNeedsWithdrawAuthority
            }

            let stake = position.account.delegation?.stake ?? 0

            guard lamports < stake else {
                throw SolanaStakingError.amountTooLarge
            }

            guard lamports >= minimum else {
                throw SolanaStakingError.belowMinimum(minimum)
            }

            guard stake - lamports >= minimum else {
                throw SolanaStakingError.remainderBelowMinimum(minimum)
            }

            guard rent <= balance else {
                throw SolanaStakingError.insufficientBalance
            }

        case let .withdraw(withdrawals):
            guard !withdrawals.isEmpty else {
                throw SolanaStakingError.nothingSelected
            }

            guard withdrawals.allSatisfy({ byAddress[$0.address]?.canWithdraw(owner: owner, at: clock) == true }) else {
                throw SolanaStakingError.cannotWithdraw
            }
        }
    }
}

// MARK: - Private

private extension SolanaStakingService {
    /// Polls briefly while the sheet is open. Only `confirmed` or better resolves anything.
    func follow(_ signature: String, account: Account, accountId: PersistentIdentifier) async -> SolanaStakingOutcome {
        for attempt in 0..<confirmationPollLimit {
            if attempt > 0 {
                try? await _Concurrency.Task.sleep(for: confirmationPollInterval)
            }

            switch try? await source.signatureStatus(signature, account: account) {
            case .confirmed:
                await resolve(signature, account: account, accountId: accountId)
                return .confirmed
            case .failed:
                await resolve(signature, account: account, accountId: accountId)
                return .failed
            case .notFound, .processed, nil:
                continue
            }
        }

        return .submitted(signature: signature)
    }

    func resolve(_ signature: String, account: Account, accountId: PersistentIdentifier) async {
        do {
            try await positionLoader.removePending(signature: signature, accountId: accountId)
        } catch {
            printError("\(account.name) staking: \(error)")
        }

        if let onChanged {
            await onChanged(account)
            return
        }

        async let position: Void? = try? stakingStateService.refreshAfterChange(account)
        try? await DI.injectOrFail(BalancesService.self).updateBalances(account, includeStaking: false)
        _ = await position
    }
}
