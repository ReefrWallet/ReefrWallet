//
//  Staking.swift
//  Reefr Wallet
//
//  Created by Andrey Yurkevich on 06.11.26.
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import BigInt
import Foundation
import SwiftData
import WalletKit

// MARK: - Staking

/// An account's staking position as last observed: the part every chain shows
/// (staked, rewards, rate) and the chain-specific ``details`` the Staking tab renders.
struct Staking: Equatable, Sendable {
    let accountId: PersistentIdentifier
    var apr: Decimal?
    var details: StakingDetails
    /// Bumped by every applied write: the UI change signal, whatever part changed.
    var revision: Int
    var rewards: BigUInt
    var staked: BigUInt
    /// When the request behind the bandwidth and energy figures started.
    var resourcesObservedAt: Date
    /// When the request behind everything else started.
    var stateObservedAt: Date
    let tokenId: PersistentIdentifier
}

/// One case per staking chain.
enum StakingDetails: Codable, Equatable, Sendable {
    case cardano(CardanoStakingDetails)
    case solana(SolanaStakingDetails)
    case sui(SuiStakingDetails)
    case tron(TronStakingDetails)

    /// Whether the blob was written by a version this one reads.
    var isCurrentVersion: Bool {
        switch self {
        case let .cardano(details): details.version == CardanoStakingDetails.currentVersion
        case let .solana(details): details.version == SolanaStakingDetails.currentVersion
        case let .sui(details): details.version == SuiStakingDetails.currentVersion
        case let .tron(details): details.version == TronStakingDetails.currentVersion
        }
    }
}

// MARK: - StakingModel

@Model
final class StakingModel {
    @Attribute(.unique) var accountStableId: String
    var apr: Decimal?
    var revision: Int
    var resourcesObservedAt: Date
    var serializedDetails: Data
    var serializedRewards: Data
    var serializedStaked: Data
    var stateObservedAt: Date

    @Relationship(deleteRule: .noAction)
    var account: AccountModel

    @Relationship(deleteRule: .noAction)
    var token: TokenModel

    init(account: AccountModel, token: TokenModel, staking: Staking) throws {
        accountStableId = "\(account.id)"
        apr = staking.apr
        revision = staking.revision
        resourcesObservedAt = staking.resourcesObservedAt
        serializedDetails = try staking.details.encoded()
        serializedRewards = staking.rewards.serialize()
        serializedStaked = staking.staked.serialize()
        stateObservedAt = staking.stateObservedAt
        self.account = account
        self.token = token
    }
}

extension Staking {
    /// `nil` if the stored details can't be decoded (written by an incompatible version): refetched then.
    init?(model: StakingModel) {
        guard
            let details: StakingDetails = try? model.serializedDetails.decoded(),
            details.isCurrentVersion
        else {
            return nil
        }

        accountId = model.account.id
        apr = model.apr
        self.details = details
        revision = model.revision
        rewards = BigUInt(model.serializedRewards)
        staked = BigUInt(model.serializedStaked)
        resourcesObservedAt = model.resourcesObservedAt
        stateObservedAt = model.stateObservedAt
        tokenId = model.token.id
    }
}

extension StakingModel {
    /// USD value of the staked amount at the token's last quote.
    var stakedUSDValue: Decimal {
        // Cardano's delegated stake stays spendable and can include other keys' UTxOs: only rewards count.
        let details: StakingDetails? = try? serializedDetails.decoded()
        let counted: BigUInt

        if case .cardano? = details {
            counted = BigUInt(serializedRewards)
        } else {
            counted = BigUInt(serializedStaked)
        }

        let amount = Decimal(sign: .plus, exponent: -Int(token.decimalsCount), significand: Decimal(counted))
        return amount * (token.usdPrice ?? 0)
    }

    func update(from staking: Staking) throws {
        apr = staking.apr
        revision = staking.revision
        resourcesObservedAt = staking.resourcesObservedAt
        serializedDetails = try staking.details.encoded()
        serializedRewards = staking.rewards.serialize()
        serializedStaked = staking.staked.serialize()
        stateObservedAt = staking.stateObservedAt
    }
}
