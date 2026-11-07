//
//  CardanoStakingService.swift
//  Reefr Wallet
//
//  Created by Andrey Yurkevich on 08.11.26.
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import BigInt
import Foundation
import SwiftData
import WalletKit

// MARK: - CardanoStakingFailure

enum CardanoStakingFailure: LocalizedError, Equatable {
    case alreadyRegistered
    case drepRequired
    case drepUnavailable
    case expiredBeforeSending
    case missingRefund
    case noRewards
    case notEnoughADA(shortfall: BigUInt)
    case notRegistered
    case poolUnavailable
    case rejected(String)
    case submissionUnresolved
    case trezorUnavailable
    case unchanged
    case watchOnly

    var errorDescription: String? {
        switch self {
        case .alreadyRegistered: String(localized: .cardanoStakingErrorAlreadyRegistered)
        case .drepRequired: String(localized: .cardanoStakingErrorDrepRequired)
        case .drepUnavailable: String(localized: .cardanoStakingErrorDrepUnavailable)
        case .expiredBeforeSending: String(localized: .cardanoStakingOutcomeSignAgainNote)
        case .missingRefund: String(localized: .cardanoStakingErrorMissingRefund)
        case .noRewards: String(localized: .cardanoStakingErrorNoRewards)
        case let .notEnoughADA(shortfall):
            String(localized: .cardanoStakingErrorNotEnoughAda(CardanoStakingFormat.ada(shortfall)))
        case .notRegistered: String(localized: .cardanoStakingErrorNotRegistered)
        case .poolUnavailable: String(localized: .cardanoStakingErrorPoolUnavailable)
        case let .rejected(reason): String(localized: .cardanoStakingErrorRejected(reason))
        case .submissionUnresolved: String(localized: .cardanoStakingNotePaused)
        case .trezorUnavailable: String(localized: .cardanoStakingErrorTrezorUnavailable)
        case .unchanged: String(localized: .cardanoStakingErrorUnchanged)
        case .watchOnly: String(localized: .cardanoStakingErrorWatchOnly)
        }
    }
}

// MARK: - CardanoStakingOutcome

/// What became of a broadcast, as far as is known when the wait ends.
enum CardanoStakingOutcome: Equatable {
    /// On chain.
    case confirmed
    /// Can no longer land; nothing was applied.
    case expired(hash: String)
    /// Not resolved yet. Staking stays paused, and position refreshes keep checking.
    case submitted(hash: String)
}

/// What a transaction is in the larger action it belongs to.
enum CardanoStepRole: Equatable, Sendable {
    /// The action is the transaction.
    case standalone
    /// Step 1 of 2: a vote delegation that lets `intent` follow.
    case voteDelegation(intent: CardanoStakingWorkflow.Intent, drep: CardanoDRep)
    /// Step 2 of 2: the withdrawal or deregistration itself.
    case finalStep
}

// MARK: - CardanoStakingFormat

enum CardanoStakingFormat {
    private static let lovelacePerAda = Decimal(1_000_000)

    /// Six decimals when needed: a fee is 0.172233 ADA.
    static func ada(_ lovelace: BigUInt) -> String {
        let amount = decimalAda(lovelace).formatted(.number.precision(.fractionLength(0...6)))
        return String(localized: .commonAmountWithSymbol(amount, "ADA"))
    }

    static func ada(_ lovelace: UInt64) -> String {
        ada(BigUInt(lovelace))
    }

    static func decimalAda(_ lovelace: BigUInt) -> Decimal {
        Decimal(string: lovelace.description).map { $0 / lovelacePerAda } ?? 0
    }

    /// `2.5%`, from Blockfrost's fraction.
    static func percent(_ fraction: Double) -> String {
        (fraction).formatted(.percent.precision(.fractionLength(0...2)))
    }
}

// MARK: - CardanoStakingService

/// Native ADA staking (ADR-059): validates an action against the live position, builds it, signs
/// it, records it, broadcasts those exact bytes and follows what becomes of it.
final class CardanoStakingService: @unchecked Sendable {
    /// A transaction with less validity than this is signed again rather than sent.
    static let minimumValiditySeconds: Int64 = 600

    private let confirmationPollInterval: Duration
    private let confirmationPollLimit: Int
    private let injectedPositionLoader: CardanoStakingPositionLoader?
    private let injectedSource: (any CardanoStakingSource)?
    private let injectedStakingStateService: StakingStateService?
    private let onChanged: (@Sendable (Account) async -> Void)?

    /// Collaborators default to the DI container's; tests pass their own.
    init(
        positionLoader: CardanoStakingPositionLoader? = nil,
        source: (any CardanoStakingSource)? = nil,
        stakingStateService: StakingStateService? = nil,
        confirmationPollInterval: Duration = .seconds(4),
        confirmationPollLimit: Int = 20,
        onChanged: (@Sendable (Account) async -> Void)? = nil
    ) {
        self.confirmationPollInterval = confirmationPollInterval
        self.confirmationPollLimit = confirmationPollLimit
        injectedPositionLoader = positionLoader
        injectedSource = source
        injectedStakingStateService = stakingStateService
        self.onChanged = onChanged
    }

    private var positionLoader: CardanoStakingPositionLoader {
        injectedPositionLoader ?? DI.injectOrFail(CardanoStakingPositionLoader.self)
    }

    private var source: any CardanoStakingSource {
        injectedSource ?? CardanoNodeStakingSource()
    }

    private var stakingStateService: StakingStateService {
        injectedStakingStateService ?? DI.injectOrFail(StakingStateService.self)
    }

    // MARK: Reading

    /// Lovelace the account can sign for: what a staking transaction may spend.
    func availableBalance(for account: Account) async throws -> BigUInt {
        try await source.availableBalance(for: account)
    }

    /// The pools the picker offers.
    func pools(for account: Account) async throws -> [CardanoPool] {
        try await source.pools(account: account)
    }

    /// A pasted or current pool, `nil` when it can't be delegated to.
    func pool(_ id: String, account: Account) async throws -> CardanoPool? {
        try await source.pool(id, account: account)
    }

    /// A pasted DRep id, `nil` when it isn't registered or has retired.
    func drep(_ id: String, account: Account) async throws -> CardanoDRepInfo? {
        guard let info = try await source.drep(id, account: account), info.isActive else {
            return nil
        }

        return info
    }

    // MARK: Writing

    /// Validates `action` against the account's live position and builds it. Nothing is signed.
    ///
    /// - Throws: ``CardanoStakingFailure`` when the action isn't allowed or the account can't fund it.
    func prepare(
        _ action: CardanoStakingAction,
        account: Account,
        signer: KeyStore.Kind
    ) async throws -> CardanoPreparedStaking {
        guard let accountId = account.id else {
            throw ReefrError.invalidData
        }

        try Self.requireSigner(signer)

        guard try await positionLoader.pendingSubmissions(accountId: accountId).isEmpty else {
            throw CardanoStakingFailure.submissionUnresolved
        }

        let startedAt = Date()
        let read = try await source.read(for: account)
        try await positionLoader.record(read: read, startedAt: startedAt, account: account)

        try Self.validate(action, read: read)
        try await revalidate(action, account: account)

        do {
            return try await source.prepare(action, read: read, account: account)
        } catch let error as CardanoStakingError {
            throw Self.failure(error)
        }
    }

    func sign(_ prepared: CardanoPreparedStaking, account: Account) async throws -> Data {
        try await source.sign(prepared, account: account)
    }

    /// Sends exactly what was signed, having first recorded it so its outcome survives a crash.
    ///
    /// - Throws: ``CardanoStakingFailure/expiredBeforeSending`` if it took too long to sign:
    ///   nothing was sent and it needs a new signature. ``CardanoStakingFailure/rejected(_:)`` if
    ///   the ledger rejected it: it wasn't submitted. Any other send failure may still have
    ///   landed, so it's followed like a success.
    func submit(
        _ prepared: CardanoPreparedStaking,
        signed: Data,
        account: Account,
        role: CardanoStepRole = .standalone
    ) async throws -> CardanoStakingOutcome {
        guard let accountId = account.id, let ttl = prepared.unsigned.ttl else {
            throw ReefrError.invalidData
        }

        guard try await source.secondsRemaining(ttl: ttl, account: account) >= Self.minimumValiditySeconds else {
            throw CardanoStakingFailure.expiredBeforeSending
        }

        let hash = try prepared.hash()

        if case let .voteDelegation(intent, drep) = role {
            let existing = try await positionLoader.workflow(accountId: accountId)

            // A retry may choose another DRep: the workflow follows the one being sent.
            var workflow = existing ?? CardanoStakingWorkflow(
                drep: drep,
                intent: intent,
                phase: .needsVoteDelegation(notice: nil),
                updatedAt: Date()
            )

            workflow.drep = drep
            workflow.updatedAt = Date()
            try await positionLoader.setWorkflow(workflow, accountId: accountId)
        }

        let pending = prepared.pendingSubmission ?? CardanoPendingSubmission(hash: hash, ttl: ttl)
        try await positionLoader.addPending(pending, accountId: accountId)

        do {
            try await markPending(hash, role: role, accountId: accountId)
        } catch {
            try? await positionLoader.removePending(hash: hash, accountId: accountId)
            throw error
        }

        do {
            _ = try await source.broadcast(prepared, signed: signed, account: account)
        } catch {
            if let reason = Self.ledgerRejection(of: error) {
                try await positionLoader.resolve(hash: hash, accountId: accountId) { Self.failed($0, role: role) }
                throw CardanoStakingFailure.rejected(reason)
            }
        }

        return await follow(hash, ttl: ttl, inputs: pending.inputs, account: account, accountId: accountId)
    }

    /// Checks unresolved transactions now.
    func checkAgain(_ account: Account) async throws {
        guard let accountId = account.id else {
            throw ReefrError.invalidData
        }

        await positionLoader.reconcilePending(account, accountId: accountId)
    }

    /// Whether `hash` is still waiting to be resolved.
    func isPending(_ hash: String, account: Account) async -> Bool {
        guard let accountId = account.id else {
            return false
        }

        let pending = try? await positionLoader.pendingSubmissions(accountId: accountId)
        return pending?.contains { $0.hash == hash } ?? false
    }

    /// Drops the stored two-step workflow. A pending submission stays: it keeps blocking staking
    /// actions and is reconciled as usual, only refreshing once it resolves.
    func cancelWorkflow(_ account: Account) async throws {
        guard let accountId = account.id else {
            throw ReefrError.invalidData
        }

        try await positionLoader.setWorkflow(nil, accountId: accountId)
    }

    // MARK: Validation

    /// A step the ledger refused goes back to where it was asked for, with a notice.
    static func failed(_ workflow: CardanoStakingWorkflow?, role: CardanoStepRole) -> CardanoStakingWorkflow? {
        guard var workflow else {
            return nil
        }

        switch role {
        case .standalone:
            return workflow
        case .voteDelegation:
            workflow.phase = .needsVoteDelegation(notice: .failed)
        case .finalStep:
            workflow.phase = .readyForFinalStep(notice: .failed)
        }

        workflow.updatedAt = Date()
        return workflow
    }

    /// Whether the account's own signer can authorize staking transactions here.
    static func requireSigner(_ kind: KeyStore.Kind) throws {
        switch kind {
        case .local:
            return
        case .trezor:
            #if os(iOS)
            throw CardanoStakingFailure.trezorUnavailable
            #endif
        case .watchOnly:
            throw CardanoStakingFailure.watchOnly
        }
    }

    /// Whether `action` is allowed given the stake key's state. Funding is checked by the build alone.
    static func validate(_ action: CardanoStakingAction, read: CardanoStakingRead) throws {
        switch action {
        case let .stake(_, drep):
            guard !read.registered else {
                throw CardanoStakingFailure.alreadyRegistered
            }

            _ = drep

        case let .changePool(pool):
            guard read.registered else {
                throw CardanoStakingFailure.notRegistered
            }

            guard read.poolId != pool else {
                throw CardanoStakingFailure.unchanged
            }

        case let .changeDRep(drep):
            guard read.registered else {
                throw CardanoStakingFailure.notRegistered
            }

            guard read.drep != drep else {
                throw CardanoStakingFailure.unchanged
            }

        case .withdraw:
            guard read.registered else {
                throw CardanoStakingFailure.notRegistered
            }

            guard read.withdrawable > 0 else {
                throw CardanoStakingFailure.noRewards
            }

            guard !CardanoClient.needsDRep(action, read: read) else {
                throw CardanoStakingFailure.drepRequired
            }

        case .stopStaking:
            guard read.registered else {
                throw CardanoStakingFailure.notRegistered
            }

            guard read.refundDeposit != nil else {
                throw CardanoStakingFailure.missingRefund
            }

            guard !CardanoClient.needsDRep(action, read: read) else {
                throw CardanoStakingFailure.drepRequired
            }
        }
    }

    /// The picker's cache can be a day old: what's chosen is checked again just before building.
    private func revalidate(_ action: CardanoStakingAction, account: Account) async throws {
        var poolId: String?
        var drep: CardanoDRep?

        switch action {
        case let .stake(pool, chosen):
            poolId = pool
            drep = chosen
        case let .changePool(pool):
            poolId = pool
        case let .changeDRep(chosen):
            drep = chosen
        case .stopStaking, .withdraw:
            break
        }

        if let poolId, try await source.pool(poolId, account: account) == nil {
            throw CardanoStakingFailure.poolUnavailable
        }

        if case let .id(id)? = drep, try await source.drep(id, account: account)?.isActive != true {
            throw CardanoStakingFailure.drepUnavailable
        }
    }

    static func failure(_ error: CardanoStakingError) -> CardanoStakingFailure {
        switch error {
        case .drepUnavailable: .drepUnavailable
        case .missingRefund: .missingRefund
        case let .notEnoughADA(shortfall): .notEnoughADA(shortfall: shortfall)
        case .poolUnavailable: .poolUnavailable
        case .rewardsOutstanding: .noRewards
        case .unregistered: .notRegistered
        }
    }

    /// The reason a Blockfrost rejection of the ledger gives, or `nil` if the error says nothing
    /// about the transaction itself (a network or server failure, which may still have landed).
    static func ledgerRejection(of error: Error) -> String? {
        guard case let WalletKitError.internalError(message) = error else {
            return nil
        }

        guard message.contains("\"status_code\":400") || message.contains("transaction submit error") else {
            return nil
        }

        return message
    }
}

// MARK: - Private

private extension CardanoStakingService {
    /// Points the workflow at the submission it now waits for.
    func markPending(_ hash: String, role: CardanoStepRole, accountId: PersistentIdentifier) async throws {
        guard var workflow = try await positionLoader.workflow(accountId: accountId) else {
            return
        }

        switch role {
        case .standalone:
            return
        case .voteDelegation:
            workflow.phase = .voteDelegationPending(hash: hash)
        case .finalStep:
            workflow.phase = .finalStepPending(hash: hash)
        }

        workflow.updatedAt = Date()
        try await positionLoader.setWorkflow(workflow, accountId: accountId)
    }

    /// Polls while the sheet is open. Only a transaction on chain, or one past saving, resolves.
    func follow(
        _ hash: String,
        ttl: UInt64,
        inputs: [CardanoSpentInput],
        account: Account,
        accountId: PersistentIdentifier
    ) async -> CardanoStakingOutcome {
        let pending = CardanoPendingSubmission(hash: hash, inputs: inputs, ttl: ttl)

        for attempt in 0..<confirmationPollLimit {
            if attempt > 0 {
                try? await _Concurrency.Task.sleep(for: confirmationPollInterval)
            }

            switch try? await source.submissionState(pending, account: account) {
            case .confirmed:
                await resolve(hash, state: .confirmed, account: account, accountId: accountId)
                return .confirmed
            case .expired:
                await resolve(hash, state: .expired, account: account, accountId: accountId)
                return .expired(hash: hash)
            case .pending, nil:
                continue
            }
        }

        return .submitted(hash: hash)
    }

    func resolve(
        _ hash: String,
        state: CardanoSubmissionState,
        account: Account,
        accountId: PersistentIdentifier
    ) async {
        do {
            try await positionLoader.resolve(hash: hash, accountId: accountId) {
                CardanoStakingPositionLoader.resolved($0, hash: hash, state: state)
            }
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
} // swiftlint:disable:this file_length
