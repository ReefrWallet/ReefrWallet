//
//  SuiStakingService.swift
//  Reefr Wallet
//
//  Created by Andrey Yurkevich on 08.11.26.
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import Foundation
import SwiftData
import WalletKit

// MARK: - SuiStakingServiceError

enum SuiStakingServiceError: LocalizedError, Equatable {
    case belowMinimum(UInt64)
    case gasUnstable
    case insufficientBalance
    /// The node refused the transaction itself; nothing was sent.
    case rejected
    case remainderBelowMinimum(UInt64)
    case simulationFailed(String)
    case stakeChanged
    case submissionUnresolved
    /// The endpoint is not on the network the transaction was prepared for; nothing was sent.
    case wrongNetwork

    var errorDescription: String? {
        switch self {
        case let .belowMinimum(mist):
            String(localized: .suiStakingErrorBelowMinimum(SuiStakingFormat.sui(mist)))
        case .gasUnstable:
            String(localized: .suiStakingErrorGasUnstable)
        case .insufficientBalance:
            String(localized: .suiStakingErrorInsufficientBalance)
        case .rejected:
            String(localized: .suiStakingErrorRejected)
        case let .remainderBelowMinimum(mist):
            String(localized: .suiStakingErrorRemainderBelowMinimum(SuiStakingFormat.sui(mist)))
        case let .simulationFailed(reason):
            String(localized: .suiStakingErrorSimulationFailed(reason))
        case .stakeChanged:
            String(localized: .suiStakingErrorStakeChanged)
        case .submissionUnresolved:
            String(localized: .suiStakingNotePaused)
        case .wrongNetwork:
            String(localized: .suiStakingErrorWrongNetwork)
        }
    }
}

// MARK: - SuiStakingOutcome

/// What became of a broadcast, as far as is known when the wait ends.
enum SuiStakingOutcome: Equatable {
    /// Applied; gas was charged.
    case confirmed
    /// Landed and failed: staking changes reverted, gas was charged.
    case failed
    /// Proven never to have run, and it never will: it expired, or another transaction spent its inputs.
    case notExecuted
    /// Not resolved yet. Staking stays paused, and position refreshes keep checking.
    case submitted(digest: String)
}

// MARK: - SuiStakingFormat

enum SuiStakingFormat {
    private static let mistPerSui = Decimal(1_000_000_000)

    /// All nine decimals when needed.
    static func sui(_ mist: UInt64) -> String {
        let amount = decimalSui(mist).formatted(.number.precision(.fractionLength(0...9)))
        return String(localized: .commonAmountWithSymbol(amount, "SUI"))
    }

    static func decimalSui(_ mist: UInt64) -> Decimal {
        Decimal(mist) / mistPerSui
    }
}

// MARK: - SuiStakingService

/// Native SUI staking (ADR-060): validates an action against the live position, prepares it, signs it,
/// records it, broadcasts those exact bytes and follows what becomes of it.
final class SuiStakingService: @unchecked Sendable {
    private let confirmationPollInterval: Duration
    private let confirmationPollLimit: Int
    private let injectedPositionLoader: SuiStakingPositionLoader?
    private let injectedSource: (any SuiStakingSource)?
    private let injectedStakingStateService: StakingStateService?
    private let now: @Sendable () -> Date
    private let onChanged: (@Sendable (Account) async -> Void)?

    /// Collaborators default to the DI container's; tests pass their own.
    init(
        positionLoader: SuiStakingPositionLoader? = nil,
        source: (any SuiStakingSource)? = nil,
        stakingStateService: StakingStateService? = nil,
        confirmationPollInterval: Duration = .seconds(2),
        confirmationPollLimit: Int = 15,
        now: @escaping @Sendable () -> Date = { Date() },
        onChanged: (@Sendable (Account) async -> Void)? = nil
    ) {
        self.confirmationPollInterval = confirmationPollInterval
        self.confirmationPollLimit = confirmationPollLimit
        injectedPositionLoader = positionLoader
        injectedSource = source
        injectedStakingStateService = stakingStateService
        self.now = now
        self.onChanged = onChanged
    }

    private var positionLoader: SuiStakingPositionLoader {
        injectedPositionLoader ?? DI.injectOrFail(SuiStakingPositionLoader.self)
    }

    private var source: any SuiStakingSource {
        injectedSource ?? SuiNodeStakingSource()
    }

    private var stakingStateService: StakingStateService {
        injectedStakingStateService ?? DI.injectOrFail(StakingStateService.self)
    }

    // MARK: Reading

    /// `account`'s liquid SUI, in MIST.
    func availableBalance(for account: Account) async throws -> UInt64 {
        try await source.liquidBalance(for: account)
    }

    /// The active validators, by name.
    func validators(for account: Account) async -> [SuiValidator] {
        await positionLoader.validators(for: account)
    }

    /// The most that can be staked from `liquid`, keeping gas and enough to unstake later. An estimate:
    /// the exact transaction may need a larger budget, which ``prepare(_:account:)`` then reports.
    static func maxStake(liquid: UInt64) -> UInt64 {
        SuiStakingFunding.maximumStake(liquid: liquid, gasBudget: SuiStakingFunding.minimumGasBudget) ?? 0
    }

    // MARK: Writing

    /// Validates `action` against the account's live position and prepares it. Nothing is signed.
    ///
    /// - Throws: ``SuiStakingServiceError`` when the action isn't allowed or simulation rejects it.
    func prepare(_ action: SuiStakingAction, account: Account) async throws -> SuiPreparedStaking {
        guard let accountId = account.id else {
            throw ReefrError.invalidData
        }

        guard try await positionLoader.pendingSubmissions(accountId: accountId).isEmpty else {
            throw SuiStakingServiceError.submissionUnresolved
        }

        // The position row must exist before anything can be recorded against it.
        let startedAt = now()
        let read = try await source.read(for: account)
        try await positionLoader.record(read: read, startedAt: startedAt, account: account)

        do {
            return try await source.prepare(action, account: account)
        } catch let error as SuiStakingError {
            throw Self.map(error)
        }
    }

    func sign(_ prepared: SuiPreparedStaking, account: Account) async throws -> Data {
        try await source.sign(prepared, account: account)
    }

    /// Sends exactly what was signed, having first recorded it, indivisibly, so its outcome survives a
    /// crash and no second transaction can be sent meanwhile.
    ///
    /// - Throws: ``SuiStakingServiceError/submissionUnresolved`` if another transaction is unresolved:
    ///   nothing was sent. ``SuiStakingServiceError/rejected`` and ``SuiStakingServiceError/wrongNetwork``
    ///   mean nothing was sent either. Any other send failure may still have landed, so it's followed like
    ///   a success.
    func submit(_ prepared: SuiPreparedStaking, signature: Data, account: Account) async throws -> SuiStakingOutcome {
        guard let accountId = account.id else {
            throw ReefrError.invalidData
        }

        let submission = SuiPendingSubmission(prepared: prepared, signature: signature, createdAt: now())

        guard try await positionLoader.claim(submission, accountId: accountId) else {
            throw SuiStakingServiceError.submissionUnresolved
        }

        switch await source.broadcast(submission, isOriginalSend: true, account: account) {
        case .released:
            try await positionLoader.removePending(digest: submission.digest, accountId: accountId)
            throw SuiStakingServiceError.rejected
        case .chainMismatch:
            try await positionLoader.removePending(digest: submission.digest, accountId: accountId)
            throw SuiStakingServiceError.wrongNetwork
        case .accepted, .keepPending:
            await source.recordBroadcast(digest: submission.digest, account: account)
        }

        return await follow(submission, account: account, accountId: accountId)
    }

    /// Checks unresolved transactions now, sending any still valid one again first.
    func checkAgain(_ account: Account) async throws {
        guard let accountId = account.id else {
            throw ReefrError.invalidData
        }

        await positionLoader.reconcilePending(account, accountId: accountId, rebroadcast: true)
    }

    /// What the latest check of the transaction `digest` found, if it has been checked.
    func latestUpdate(for digest: String) async -> SuiSubmissionResolution? {
        await positionLoader.latestUpdate(for: digest)
    }

    // MARK: Errors

    static func map(_ error: SuiStakingError) -> SuiStakingServiceError {
        switch error {
        case let .belowMinimumStake(minimum): .belowMinimum(minimum)
        case .gasUnstable: .gasUnstable
        case .insufficientFunds: .insufficientBalance
        case let .remainderBelowMinimum(minimum): .remainderBelowMinimum(minimum)
        case let .simulationFailed(reason): .simulationFailed(reason)
        case .stakeChanged: .stakeChanged
        }
    }
}

// MARK: - Private

private extension SuiStakingService {
    /// Polls briefly while the sheet is open. Only a finalized result, or a proof it never ran, resolves anything.
    func follow(
        _ submission: SuiPendingSubmission,
        account: Account,
        accountId: PersistentIdentifier
    ) async -> SuiStakingOutcome {
        for attempt in 0..<confirmationPollLimit {
            if attempt > 0 {
                try? await _Concurrency.Task.sleep(for: confirmationPollInterval)
            }

            switch await source.resolve(submission, account: account) {
            case .succeeded:
                await resolve(submission, account: account, accountId: accountId)
                return .confirmed
            case .failed:
                await resolve(submission, account: account, accountId: accountId)
                return .failed
            case .notExecuted:
                do {
                    try await source.clearNonExecuted(digest: submission.digest, account: account)
                } catch {
                    // The claim stays, so a later check retries the cleanup.
                    printError("\(account.name) staking: \(error)")
                    continue
                }

                await resolve(submission, account: account, accountId: accountId)
                return .notExecuted
            case .unresolved:
                continue
            }
        }

        return .submitted(digest: submission.digest)
    }

    func resolve(_ submission: SuiPendingSubmission, account: Account, accountId: PersistentIdentifier) async {
        do {
            try await positionLoader.removePending(digest: submission.digest, accountId: accountId)
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
