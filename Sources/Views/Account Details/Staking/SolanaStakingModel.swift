//
//  SolanaStakingModel.swift
//  Reefr Wallet
//
//  Created by Andrey Yurkevich on 06.11.26.
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import Foundation
import Observation
import WalletKit

// MARK: - SolanaStakingSheetKind

/// The staking sheets of ADR-054, presented from the Staking tab.
enum SolanaStakingSheetKind: String, Identifiable {
    case stake
    case unstake
    case withdraw

    var id: String { rawValue }
}

// MARK: - SolanaStakingModel

/// The stake accounts of one Solana account, shared by the Staking tab, its toolbar actions and
/// its sheets. The position is the stored one (``apply(_:)``), kept current by
/// ``StakingStateService``; sheets still read the live one before signing.
@MainActor
@Observable
final class SolanaStakingModel {
    let account: Account
    /// Watch-only accounts show the position but can't change it.
    let canSign: Bool
    let isHardware: Bool

    var sheet: SolanaStakingSheetKind?

    private(set) var details: SolanaStakingDetails?
    private(set) var error: String?
    private(set) var isLoading = false
    private(set) var solPrice: Decimal?
    private(set) var validators: [SolanaValidator] = []

    private var positionLoader: SolanaStakingPositionLoader {
        DI.injectOrFail(SolanaStakingPositionLoader.self)
    }

    private var service: SolanaStakingService {
        DI.injectOrFail(SolanaStakingService.self)
    }

    private var stakingStateService: StakingStateService {
        DI.injectOrFail(StakingStateService.self)
    }

    nonisolated init(account: Account, keyStore: KeyStore) {
        self.account = account
        canSign = keyStore.kind != .watchOnly
        isHardware = keyStore.kind == .trezor
    }

    #if DEBUG
    /// For previews, which have no store or services.
    init(
        account: Account,
        canSign: Bool,
        details: SolanaStakingDetails?,
        error: String? = nil,
        solPrice: Decimal? = nil
    ) {
        self.account = account
        self.canSign = canSign
        self.details = details
        self.error = error
        self.solPrice = solPrice
        isHardware = false
    }
    #endif

    /// Shows the stored position (`nil` until the first read of the account).
    func apply(_ staking: Staking?) {
        if case let .solana(solana)? = staking?.details {
            details = solana
        } else {
            details = nil
        }
    }

    /// Re-reads the position into the store, and the validators and (once) SOL price.
    func refresh() async {
        guard !isLoading else {
            return
        }

        isLoading = true
        defer {
            isLoading = false
        }

        do {
            try await stakingStateService.refresh(account)
            error = nil
        } catch {
            if !Task.isCancelled {
                self.error = error.localizedDescription
            }
        }

        await refreshValidators()

        if solPrice == nil {
            await loadPrice()
        }
    }

    /// Takes the loader's current list; its TTL cache decides whether this reaches the network.
    func refreshValidators() async {
        validators = await positionLoader.validators(for: account)
    }

    /// Checks unresolved transactions now, from the tab's Check Again.
    func checkAgain() async {
        try? await service.checkAgain(account)
    }

    // MARK: Derived

    var positions: [SolanaStakePosition] {
        details?.positions ?? []
    }

    var staked: UInt64 {
        details?.stakedLamports ?? 0
    }

    /// Accounts holding stake or stuck behind someone else's authority or a lockup.
    var stakeAccounts: [SolanaStakePosition] {
        guard let details else {
            return []
        }

        return details.positions.filter { position in
            switch position.status {
            case .activating, .active: true
            case .deactivating: false
            case .inactive, .undelegated: !position.canWithdraw(owner: account.address, at: details.clock)
            }
        }
    }

    var unstaking: [SolanaStakePosition] {
        positions.filter { $0.status == .deactivating }
    }

    /// What this wallet can withdraw now.
    var withdrawable: [SolanaStakePosition] {
        guard let details else {
            return []
        }

        return details.positions.filter { $0.canWithdraw(owner: account.address, at: details.clock) }
    }

    var withdrawableLamports: UInt64 {
        withdrawable.map(\.account.lamports).saturatingSum
    }

    /// The first transaction whose outcome is still open: staking is paused until it resolves.
    var unresolved: SolanaPendingSubmission? {
        details?.pendingSubmissions.first
    }

    var canStake: Bool {
        canSign && details != nil && unresolved == nil
    }

    var canUnstake: Bool {
        canSign && unresolved == nil && positions.contains { $0.canUnstake(owner: account.address) }
    }

    var canWithdraw: Bool {
        canSign && unresolved == nil && !withdrawable.isEmpty
    }

    var isDiscoveryDegraded: Bool {
        details?.discovery == .degraded
    }

    /// Whether Unstake belongs in the toolbar at all: Not Staked shows only Stake.
    var isStaked: Bool {
        !positions.isEmpty
    }

    func name(of voter: String?) -> String {
        guard let voter else {
            return String(localized: .solanaStakingNoValidator)
        }

        return details?.validators[voter]?.name
            ?? validators.first { $0.voteAddress == voter }?.name
            ?? voter.shortened(prefix: 6, suffix: 4)
    }

    /// `Active`, or why this wallet can't act on the account.
    func statusText(_ position: SolanaStakePosition) -> String {
        Self.statusText(position, owner: account.address, clock: details?.clock)
    }

    nonisolated static func statusText(
        _ position: SolanaStakePosition,
        owner: String,
        clock: SolanaClock?
    ) -> String {
        if position.account.staker != owner, position.status == .active || position.status == .activating {
            return String(localized: .solanaStakingStatusCannotUnstake)
        }

        if let clock, position.account.isLocked(at: clock) {
            return String(localized: .solanaStakingStatusLocked)
        }

        if position.account.withdrawer != owner {
            return String(localized: .solanaStakingStatusCannotWithdraw)
        }

        switch position.status {
        case .activating: return String(localized: .solanaStakingStatusActivating)
        case .active: return String(localized: .solanaStakingStatusActive)
        case .deactivating: return String(localized: .solanaStakingStatusDeactivating)
        case .inactive, .undelegated: return String(localized: .solanaStakingStatusInactive)
        }
    }

    /// `Next epoch in about 6 h`: the next boundary, not completion, which can take several
    /// epochs. `nil` when no slot duration is known.
    func nextEpochText(now: Date = Date()) -> String? {
        details.flatMap { Self.nextEpochText(details: $0, now: now) }
    }

    nonisolated static func nextEpochText(details: SolanaStakingDetails, now: Date) -> String? {
        guard let slotDuration = details.slotDuration else {
            return nil
        }

        let total = Double(details.slotsRemainingInEpoch) * slotDuration
        let remaining = total - now.timeIntervalSince(details.observedAt)

        guard remaining > 0 else {
            return String(localized: .solanaStakingEpochEndingSoon)
        }

        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = remaining >= 3_600 ? [.day, .hour] : [.minute]
        formatter.maximumUnitCount = 2
        formatter.unitsStyle = .abbreviated

        let text = formatter.string(from: max(remaining, 60)) ?? ""
        return String(localized: .solanaStakingNextEpoch(text))
    }

    /// The summary's second line, per ADR-054: never a zero for an unknown; `nil` when there's
    /// nothing to report.
    nonisolated static func rewardsLine(details: SolanaStakingDetails, solPrice: Decimal?) -> String? {
        let apy = details.apy.map {
            String(localized: .solanaStakingApy(($0 / 100).formatted(.percent.precision(.fractionLength(0...2)))))
        }

        func withDetails(_ line: String, lamports: UInt64?) -> String {
            let usd = lamports.flatMap { lamports in
                solPrice.map { "\((SolanaStakingFormat.decimalSol(lamports) * $0).formattedAbbreviated()) US$" }
            }

            let parts = [usd, apy].compactMap { $0 }.joined(separator: " \(String.dot) ")
            return parts.isEmpty ? line : "\(line) (\(parts))"
        }

        guard !details.positions.isEmpty else {
            return nil
        }

        guard let rewards = details.rewards else {
            return withDetails(String(localized: .solanaStakingRewardsUnavailable), lamports: nil)
        }

        let isCurrent = rewards.epoch == details.targetRewardEpoch
        let isQualified = !rewards.unknownAddresses.isEmpty || details.discovery == .degraded

        if rewards.lamports == 0 {
            if isQualified {
                return withDetails(String(localized: .solanaStakingRewardsUnavailable), lamports: nil)
            }

            // Nothing earned, provably.
            return isCurrent ? apy : withDetails(String(localized: .solanaStakingRewardsUnavailable), lamports: nil)
        }

        let amount = SolanaStakingFormat.sol(rewards.lamports)
        let line: String

        switch (isCurrent, isQualified) {
        case (true, false):
            line = String(localized: .solanaStakingRewardsLastEpoch(amount))
        case (true, true):
            line = String(localized: .solanaStakingRewardsLastEpochAtLeast(amount))
        case (false, false):
            line = String(localized: .solanaStakingRewardsEpoch(Int(rewards.epoch), amount))
        case (false, true):
            line = String(localized: .solanaStakingRewardsEpochAtLeast(Int(rewards.epoch), amount))
        }

        return withDetails(line, lamports: rewards.lamports)
    }

    /// `≈ $0.22`, when the SOL price is known.
    func usdText(lamports: UInt64) -> String? {
        solPrice.map {
            let usd = SolanaStakingFormat.decimalSol(lamports) * $0
            return String(localized: .tronStakingRewardsUsd("\(usd.formattedAbbreviated()) US$"))
        }
    }

    /// Where a user can look a transaction up.
    func explorerURL(signature: String) -> URL? {
        var components = URLComponents(string: "https://solscan.io/tx/\(signature)")

        if case let .solana(network) = account.blockchain, network != .mainnet {
            components?.queryItems = [URLQueryItem(name: "cluster", value: network == .devnet ? "devnet" : "testnet")]
        }

        return components?.url
    }

    /// What the Unstake inputs describe; `nil` until they are complete. An account this wallet can
    /// split goes by its amount: all of its stake is a full unstake, and any other amount a
    /// partial one, which validation refuses when too large.
    nonisolated static func unstakeAction(
        selected: [SolanaStakePosition],
        owner: String,
        amount: UInt64?
    ) -> SolanaStakingAction? {
        guard selected.count == 1, let single = selected.first, single.account.withdrawer == owner else {
            return selected.isEmpty ? nil : .unstake(accounts: selected.map(\.account.address).sorted())
        }

        guard let amount else {
            return nil
        }

        let address = single.account.address

        return amount == single.account.delegation?.stake
            ? .unstake(accounts: [address])
            : .unstakePartial(account: address, lamports: amount)
    }

    /// `Stake 5 SOL`.
    nonisolated static func actionText(_ action: SolanaStakingAction) -> String {
        switch action {
        case let .stake(lamports, _):
            String(localized: .solanaStakingActionStake(SolanaStakingFormat.sol(lamports)))
        case let .unstake(accounts):
            String(localized: .solanaStakingActionUnstakeAccounts(accounts.count))
        case let .unstakePartial(_, lamports):
            String(localized: .solanaStakingActionUnstake(SolanaStakingFormat.sol(lamports)))
        case let .withdraw(withdrawals):
            String(localized: .solanaStakingActionWithdraw(
                SolanaStakingFormat.sol(withdrawals.map(\.lamports).saturatingSum)
            ))
        }
    }

    // MARK: Private

    private func loadPrice() async {
        let token = Token(address: nil, blockchain: account.blockchain, tokenInfo: account.blockchain.nativeToken)
        solPrice = try? await DI.injectOrFail(TokenPriceService.self).usdPrice(token, rpcURL: account.blockchain.rpcURL)
    }
}
