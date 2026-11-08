//
//  SuiStakingModel.swift
//  Reefr Wallet
//
//  Created by Andrey Yurkevich on 08.11.26.
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import Foundation
import Observation
import WalletKit

// MARK: - SuiStakingSheetKind

/// The staking sheets of ADR-060, presented from the Staking tab.
enum SuiStakingSheetKind: String, Identifiable {
    case stake
    case unstake

    var id: String { rawValue }
}

// MARK: - SuiStakingModel

/// The stakes of one Sui account, shared by the Staking tab, its toolbar actions and its sheets.
/// The position is the stored one (``apply(_:)``), kept current by ``StakingStateService``; sheets
/// still read the live one before signing.
@MainActor
@Observable
final class SuiStakingModel {
    let account: Account
    /// Watch-only and hardware accounts show the position but can't change it: Trezor has no Sui app.
    let canSign: Bool

    var sheet: SuiStakingSheetKind?

    private(set) var details: SuiStakingDetails?
    private(set) var error: String?
    private(set) var isLoading = false
    private(set) var suiPrice: Decimal?
    private(set) var validators: [SuiValidator] = []

    private var positionLoader: SuiStakingPositionLoader {
        DI.injectOrFail(SuiStakingPositionLoader.self)
    }

    private var service: SuiStakingService {
        DI.injectOrFail(SuiStakingService.self)
    }

    private var stakingStateService: StakingStateService {
        DI.injectOrFail(StakingStateService.self)
    }

    nonisolated init(account: Account, keyStore: KeyStore) {
        self.account = account
        canSign = keyStore.kind == .local
    }

    #if DEBUG
    /// For previews, which have no store or services.
    init(
        account: Account,
        canSign: Bool,
        details: SuiStakingDetails?,
        error: String? = nil,
        suiPrice: Decimal? = nil
    ) {
        self.account = account
        self.canSign = canSign
        self.details = details
        self.error = error
        self.suiPrice = suiPrice
    }
    #endif

    /// Shows the stored position (`nil` until the first read of the account).
    func apply(_ staking: Staking?) {
        if case let .sui(sui)? = staking?.details {
            details = sui
        } else {
            details = nil
        }
    }

    /// Re-reads the position into the store, and the validators and (once) SUI price.
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

        if suiPrice == nil {
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

    var positions: [SuiStakePosition] {
        details?.positions ?? []
    }

    var staked: UInt64 {
        details?.stakedMist ?? 0
    }

    /// The first transaction whose outcome is still open: staking is paused until it resolves.
    var unresolved: SuiPendingSubmission? {
        details?.pendingSubmissions.first
    }

    var isStaked: Bool {
        !positions.isEmpty
    }

    var canStake: Bool {
        canSign && details != nil && unresolved == nil
    }

    var canUnstake: Bool {
        canSign && unresolved == nil && isStaked
    }

    /// Whether the open transaction outlived its validity window without a verdict.
    var isUnresolvedPastValidity: Bool {
        guard let details, let unresolved else {
            return false
        }

        return details.epoch > unresolved.expiryEpoch
    }

    func name(of position: SuiStakePosition) -> String {
        position.validatorName
            ?? position.validatorAddress?.shortened(prefix: 6, suffix: 4)
            ?? position.stake.poolId.shortened(prefix: 6, suffix: 4)
    }

    /// `Earning`, `Starts next epoch` or `Validator left`.
    nonisolated static func statusText(_ position: SuiStakePosition) -> String {
        switch position.status {
        case .earning: String(localized: .suiStakingStatusEarning)
        case .pending: String(localized: .suiStakingStatusActivating)
        case .retired: String(localized: .suiStakingStatusRetired)
        }
    }

    /// `Next epoch in about 6 h`: Sui epochs last a day. `nil` when the node reported no timing.
    func nextEpochText(now: Date = Date()) -> String? {
        details.flatMap { Self.nextEpochText(details: $0, now: now) }
    }

    nonisolated static func nextEpochText(details: SuiStakingDetails, now: Date) -> String? {
        guard let next = details.nextEpochDate else {
            return nil
        }

        let remaining = next.timeIntervalSince(now)

        guard remaining > 0 else {
            return String(localized: .suiStakingEpochEndingSoon)
        }

        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = remaining >= 3_600 ? [.day, .hour] : [.minute]
        formatter.maximumUnitCount = 2
        formatter.unitsStyle = .abbreviated

        let text = formatter.string(from: max(remaining, 60)) ?? ""
        return String(localized: .suiStakingNextEpoch(text))
    }

    /// The summary's second line, per ADR-060: estimated, and never a zero for an unknown; `nil` when
    /// there is nothing staked.
    nonisolated static func rewardsLine(details: SuiStakingDetails, suiPrice: Decimal?) -> String? {
        guard !details.positions.isEmpty else {
            return nil
        }

        let rewards = details.estimatedRewardsMist
        let isKnown = details.positions.contains { $0.estimatedReward != nil }

        guard isKnown else {
            return String(localized: .suiStakingRewardsUnavailable)
        }

        let amount = SuiStakingFormat.sui(rewards)
        let line = details.isRewardsComplete
            ? String(localized: .suiStakingRewardsEstimated(amount))
            : String(localized: .suiStakingRewardsEstimatedAtLeast(amount))

        guard let suiPrice else {
            return line
        }

        let usd = (SuiStakingFormat.decimalSui(rewards) * suiPrice).formattedAbbreviated()
        return "\(line) (\(usd) US$)"
    }

    /// `≈ $0.22`, when the SUI price is known.
    func usdText(mist: UInt64) -> String? {
        suiPrice.map {
            let usd = SuiStakingFormat.decimalSui(mist) * $0
            return String(localized: .tronStakingRewardsUsd("\(usd.formattedAbbreviated()) US$"))
        }
    }

    /// Where a user can look a transaction up.
    func explorerURL(digest: String) -> URL? {
        let network = account.blockchain == .sui(.mainnet) ? "mainnet" : "testnet"
        return URL(string: "https://suiscan.xyz/\(network)/tx/\(digest)")
    }

    /// `Stake` or `Unstake`: the unresolved transaction's pending action; its amount isn't kept.
    nonisolated static func kindText(_ kind: SuiStakingActionKind) -> String {
        switch kind {
        case .stake: String(localized: .tronStakingStake)
        case .unstake: String(localized: .tronStakingUnstake)
        case .unstakePartial: String(localized: .suiStakingKindUnstakePartial)
        }
    }

    /// What the Unstake inputs describe; `nil` until they are complete or when `amount` is more than the
    /// stake holds. Anything below the whole stake is a partial unstake, which preparation validates.
    nonisolated static func unstakeAction(stake: SuiStakedSui?, amount: UInt64?) -> SuiStakingAction? {
        guard let stake, let amount, amount <= stake.principal else {
            return nil
        }

        return amount == stake.principal ? .unstake(stake) : .unstakePartial(stake, amount: amount)
    }

    /// Whether a stake can be split at all: both parts must hold the minimum.
    nonisolated static func canSplit(_ stake: SuiStakedSui) -> Bool {
        stake.principal >= 2 * SuiStakingFramework.minimumStake
    }

    /// What unstaking `amount` of `position` (all of it when `nil`) pays out now: the principal, and the
    /// share of the estimated rewards that goes with it. A stake that hasn't started earning has none.
    nonisolated static func estimatedPayout(_ position: SuiStakePosition, amount: UInt64?) -> UInt64? {
        let principal = position.stake.principal
        let part = amount ?? principal

        guard part > 0, part <= principal else {
            return nil
        }

        guard position.status != .pending, let reward = position.estimatedReward else {
            return part
        }

        let share = UInt64(exactly: UInt128(reward) * UInt128(part) / UInt128(principal)) ?? reward
        return part.addingReportingOverflow(share).partialValue
    }

    // MARK: Private

    private func loadPrice() async {
        let token = Token(address: nil, blockchain: account.blockchain, tokenInfo: account.blockchain.nativeToken)
        suiPrice = try? await DI.injectOrFail(TokenPriceService.self).usdPrice(token, rpcURL: account.blockchain.rpcURL)
    }
}
