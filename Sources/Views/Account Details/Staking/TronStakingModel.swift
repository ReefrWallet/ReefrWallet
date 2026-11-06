//
//  TronStakingModel.swift
//  Reefr Wallet
//
//  Created by Andrey Yurkevich on 05.11.26.
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import Foundation
import Observation
import WalletKit

// MARK: - TronStakingSheetKind

/// The staking sheets of ADR-052, presented from the Staking tab.
enum TronStakingSheetKind: String, Identifiable {
    case cancelUnstaking
    case claim
    case stake
    case unstake
    case vote
    case withdraw

    var id: String { rawValue }
}

// MARK: - TronStakingModel

/// The Stake 2.0 position of one Tron account, shared by the Staking tab, its toolbar
/// actions and its sheets. The position is the stored one (``apply(_:)``), kept current by
/// ``StakingStateService``; sheets still read the live one before signing.
@MainActor
@Observable
final class TronStakingModel {
    let account: Account
    /// Watch-only accounts show the position but can't change it.
    let canSign: Bool
    /// Trezor can't cancel unstakes (no firmware contract).
    let isHardware: Bool

    var sheet: TronStakingSheetKind?

    private(set) var error: String?
    private(set) var isLoading = false
    private(set) var representatives: [TronRepresentative] = []
    private(set) var stored: Staking?
    private(set) var trxPrice: Decimal?

    @ObservationIgnored private let positionLoader = DI.injectOrFail(TronStakingPositionLoader.self)
    @ObservationIgnored private let stakingStateService = DI.injectOrFail(StakingStateService.self)

    nonisolated init(account: Account, keyStore: KeyStore) {
        self.account = account
        canSign = keyStore.kind != .watchOnly
        isHardware = keyStore.kind == .trezor
    }

    /// Shows the stored position (`nil` until the first read of the account).
    func apply(_ staking: Staking?) {
        stored = staking
    }

    /// Re-reads the position into the store, and the representatives and (once) TRX price.
    func refresh() async {
        guard account.blockchain.supportsStaking, !isLoading else {
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

        await refreshRepresentatives()

        if trxPrice == nil {
            await loadPrice()
        }
    }

    /// Takes the loader's current list; its TTL cache decides whether this reaches the network.
    /// Pull-to-refresh updates the loader without going through ``refresh()``, so the picker
    /// asks again when it opens.
    func refreshRepresentatives() async {
        representatives = await positionLoader.representatives(for: account)
    }

    // MARK: Derived

    var state: TronStakingState? {
        guard case let .tron(details)? = stored?.details else {
            return nil
        }

        return details.state
    }

    /// Rewards outlive the stake: they stay claimable after everything is unstaked.
    var hasRewards: Bool {
        (state?.rewards ?? 0) > 0
    }

    var canClaim: Bool {
        canSign && (state?.rewards ?? 0) > 0
    }

    var canUnstake: Bool {
        canSign && (state?.totalStaked ?? 0) > 0
    }

    /// Nothing staked yet: Stake is then the only action.
    var isStaked: Bool {
        (state?.totalStaked ?? 0) > 0
    }

    /// Unstakes at `now`, classified once for every section and total: still waiting out their
    /// 14 days (soonest first), or expired since the node was read and so ready to withdraw.
    func unstakes(now: Date = Date()) -> (pending: [TronStakingState.Unfrozen], expired: [TronStakingState.Unfrozen]) {
        let entries = state?.unfrozen ?? []

        return (
            entries.filter { $0.expiration > now }.sorted { $0.expiration < $1.expiration },
            entries.filter { $0.expiration <= now }
        )
    }

    func pendingUnstakes(now: Date = Date()) -> [TronStakingState.Unfrozen] {
        unstakes(now: now).pending
    }

    /// What Cancel returns to staking; expired entries are withdrawn instead.
    func pendingUnstakeTotal(now: Date = Date()) -> UInt64 {
        pendingUnstakes(now: now).reduce(0) { $0 + $1.amount }
    }

    /// Ready to withdraw: the node's figure, plus entries that expired since it was read.
    func withdrawable(now: Date = Date()) -> UInt64 {
        max(state?.withdrawable ?? 0, unstakes(now: now).expired.reduce(0) { $0 + $1.amount })
    }

    /// Votes not yet assigned to a representative.
    var unassignedVotes: UInt64 {
        guard let state, state.votePower > state.assignedVotes else {
            return 0
        }

        return state.votePower - state.assignedVotes
    }

    func name(of address: TronAddress) -> String {
        if case let .tron(details)? = stored?.details, let name = details.representatives[address.string]?.name {
            return name
        }

        return representatives.first { $0.address == address }?.name ?? address.string.shortened(prefix: 6, suffix: 4)
    }

    /// Annual rate of the rewards: the votes' representatives' rates, weighted by votes.
    /// `nil` unless every voted representative has a known rate.
    var rewardsRate: Decimal? {
        stored?.apr
    }

    /// `≈ $0.22`, when the TRX price is known.
    func usdText(sun: UInt64) -> String? {
        usd(sun: sun).map { String(localized: .tronStakingRewardsUsd($0.formatted(.currency(code: "USD")))) }
    }

    /// USD value of `sun`, when the TRX price is known.
    func usd(sun: UInt64) -> Decimal? {
        trxPrice.map { Decimal(sun) / Decimal(1_000_000) * $0 }
    }

    // MARK: Private

    private func loadPrice() async {
        let token = Token(address: nil, blockchain: account.blockchain, tokenInfo: account.blockchain.nativeToken)
        trxPrice = try? await DI.injectOrFail(TokenPriceService.self).usdPrice(token, rpcURL: account.blockchain.rpcURL)
    }
}
