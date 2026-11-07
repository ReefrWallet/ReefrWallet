//
//  CardanoStakingModel.swift
//  Reefr Wallet
//
//  Created by Andrey Yurkevich on 08.11.26.
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import BigInt
import Foundation
import Observation
import WalletKit

// MARK: - CardanoStakingSheetKind

/// The staking sheets of ADR-059, presented from the Staking tab.
enum CardanoStakingSheetKind: String, Identifiable {
    case changeDRep
    case changePool
    case stake
    case stopStaking
    case withdraw

    var id: String { rawValue }

    var intent: CardanoStakingWorkflow.Intent? {
        switch self {
        case .stopStaking: .stopStaking
        case .withdraw: .withdraw
        default: nil
        }
    }

    init(_ intent: CardanoStakingWorkflow.Intent) {
        switch intent {
        case .stopStaking: self = .stopStaking
        case .withdraw: self = .withdraw
        }
    }
}

// MARK: - CardanoStakingModel

/// The staking position of one Cardano account, shared by the Staking tab, its toolbar actions and
/// its sheets. The position is the stored one (``apply(_:)``), kept current by
/// ``StakingStateService``; sheets still read the live one before signing.
@MainActor
@Observable
final class CardanoStakingModel {
    let account: Account
    /// Watch-only accounts show the position but can't change it; a Trezor can't on iPhone.
    let canSign: Bool
    let isHardware: Bool
    let signer: KeyStore.Kind

    var sheet: CardanoStakingSheetKind?

    private(set) var adaPrice: Decimal?
    /// Lovelace controlled by the stake address: display only.
    private(set) var delegatedStake: BigUInt = 0
    private(set) var details: CardanoStakingDetails?
    private(set) var error: String?
    private(set) var isLoading = false
    /// Lovelace withdrawable from the reward account.
    private(set) var rewards: BigUInt = 0

    private var service: CardanoStakingService {
        DI.injectOrFail(CardanoStakingService.self)
    }

    private var stakingStateService: StakingStateService {
        DI.injectOrFail(StakingStateService.self)
    }

    nonisolated init(account: Account, keyStore: KeyStore) {
        self.account = account
        isHardware = keyStore.kind == .trezor
        signer = keyStore.kind

        var canSign = keyStore.kind != .watchOnly

        #if os(iOS)
        canSign = canSign && keyStore.kind != .trezor
        #endif

        self.canSign = canSign
    }

    #if DEBUG
    /// For previews, which have no store or services.
    init(
        account: Account,
        canSign: Bool,
        details: CardanoStakingDetails?,
        delegatedStake: BigUInt = 0,
        rewards: BigUInt = 0,
        error: String? = nil,
        adaPrice: Decimal? = nil
    ) {
        self.account = account
        self.canSign = canSign
        self.details = details
        self.delegatedStake = delegatedStake
        self.rewards = rewards
        self.error = error
        self.adaPrice = adaPrice
        isHardware = false
        signer = .local
    }
    #endif

    /// Shows the stored position (`nil` until the first read of the account).
    func apply(_ staking: Staking?) {
        if case let .cardano(cardano)? = staking?.details, let staking {
            details = cardano
            delegatedStake = staking.staked
            rewards = staking.rewards
        } else {
            details = nil
            delegatedStake = 0
            rewards = 0
        }
    }

    /// Re-reads the position into the store, and (once) the ADA price.
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

        if adaPrice == nil {
            await loadPrice()
        }
    }

    /// Checks unresolved transactions now, from the tab's Check Again.
    func checkAgain() async {
        try? await service.checkAgain(account)
    }

    /// Cancels a two-step workflow. A pending submission stays and keeps blocking staking actions.
    func cancelWorkflow() async {
        try? await service.cancelWorkflow(account)
        await refresh()
    }

    // MARK: Derived

    var isRegistered: Bool {
        details?.registered ?? false
    }

    /// The first transaction whose outcome is still open: staking is paused until it resolves.
    var unresolved: CardanoPendingSubmission? {
        details?.pendingSubmissions.first
    }

    var workflow: CardanoStakingWorkflow? {
        details?.workflow
    }

    /// Nothing is in flight or half done, and this wallet can sign.
    private var isFree: Bool {
        canSign && details != nil && unresolved == nil && workflow == nil
    }

    var canStake: Bool {
        isFree && !isRegistered
    }

    var canStopStaking: Bool {
        isFree && isRegistered
    }

    var canWithdraw: Bool {
        isFree && isRegistered && rewards > 0
    }

    var canChange: Bool {
        isFree && isRegistered
    }

    /// Whether Stop Staking (rather than Stake) belongs in the toolbar's registered state.
    var isStaked: Bool {
        isRegistered
    }

    /// Whether a workflow can be continued now: its step is waiting, not in flight.
    var canContinueWorkflow: Bool {
        guard canSign, unresolved == nil, let workflow else {
            return false
        }

        switch workflow.phase {
        case .needsVoteDelegation, .readyForFinalStep: return true
        case .finalStepPending, .voteDelegationPending: return false
        }
    }

    // MARK: Names and text

    func poolName(_ pool: CardanoStakingDetails.PoolSummary) -> String {
        Self.poolName(ticker: pool.ticker, name: pool.name, poolId: pool.poolId)
    }

    nonisolated static func poolName(ticker: String?, name: String?, poolId: String) -> String {
        switch (ticker, name) {
        case let (ticker?, name?) where ticker != name: "\(ticker) \(String.dot) \(name)"
        case let (ticker?, _): ticker
        case let (_, name?): name
        default: poolId.shortened(prefix: 8, suffix: 4)
        }
    }

    func drepName(_ drep: CardanoDRep, name: String?) -> String {
        Self.drepName(drep, name: name)
    }

    nonisolated static func drepName(_ drep: CardanoDRep, name: String?) -> String {
        switch drep {
        case .abstain: String(localized: .cardanoStakingDrepAbstain)
        case .noConfidence: String(localized: .cardanoStakingDrepNoConfidence)
        case let .id(id): name ?? id.shortened(prefix: 10, suffix: 4)
        }
    }

    /// `2% margin`.
    nonisolated static func marginText(_ pool: CardanoStakingDetails.PoolSummary) -> String {
        pool.marginCost.map { String(localized: .cardanoStakingMargin(CardanoStakingFormat.percent($0))) } ?? ""
    }

    /// `Epoch 512` and its reward: only a reward actually recorded is shown, never a zero for an unknown.
    nonisolated static func rewardRow(_ reward: CardanoReward?) -> (epoch: String, amount: String)? {
        reward.map {
            let epoch = String(localized: .cardanoStakingEpochNumber(Int(clamping: $0.epoch)))
            return (epoch, CardanoStakingFormat.ada($0.amount))
        }
    }

    /// The summary's second line: when the epoch turns, and for a first delegation when rewards
    /// start. Approximate, per ADR-059: both are about boundaries, not promises.
    func timingText(now: Date = Date()) -> String? {
        guard let details else {
            return nil
        }

        var parts: [String] = []
        let remaining = details.epoch.endTime.timeIntervalSince(now)

        if remaining > 0 {
            let formatter = DateComponentsFormatter()
            formatter.allowedUnits = remaining >= 3_600 ? [.day, .hour] : [.minute]
            formatter.maximumUnitCount = 2
            formatter.unitsStyle = .abbreviated
            let text = formatter.string(from: max(remaining, 60)) ?? ""
            parts.append(String(localized: .cardanoStakingNextEpoch(text)))
        }

        if details.registered, details.pool != nil, details.latestReward == nil, details.totalEarned == 0 {
            parts.append(String(localized: .cardanoStakingRewardsStart))
        }

        return parts.isEmpty ? nil : parts.joined(separator: " \(String.dot) ")
    }

    /// `≈ $0.22`, when the ADA price is known.
    func usdText(lovelace: BigUInt) -> String? {
        adaPrice.map {
            let usd = CardanoStakingFormat.decimalAda(lovelace) * $0
            return String(localized: .tronStakingRewardsUsd("\(usd.formattedAbbreviated()) US$"))
        }
    }

    /// Where a user can look a transaction up.
    func explorerURL(hash: String) -> URL? {
        guard case let .cardano(network) = account.blockchain else {
            return nil
        }

        let host = network == .mainnet ? "cardanoscan.io" : "\(network.name.lowercased()).cardanoscan.io"
        return URL(string: "https://\(host)/transaction/\(hash)")
    }

    /// `Stake EVER · Everstake`, for the Outcome's Action row.
    nonisolated static func actionText(_ action: CardanoStakingAction, poolName: String? = nil) -> String {
        switch action {
        case .changeDRep: String(localized: .cardanoStakingActionChangeDrep)
        case .changePool: String(localized: .cardanoStakingActionChangePool)
        case .stake: String(localized: .cardanoStakingActionStake(poolName ?? ""))
        case .stopStaking: String(localized: .cardanoStakingActionStopStaking)
        case .withdraw: String(localized: .cardanoStakingActionWithdraw)
        }
    }

    // MARK: Private

    private func loadPrice() async {
        let token = Token(address: nil, blockchain: account.blockchain, tokenInfo: account.blockchain.nativeToken)
        adaPrice = try? await DI.injectOrFail(TokenPriceService.self).usdPrice(token, rpcURL: account.blockchain.rpcURL)
    }
}
