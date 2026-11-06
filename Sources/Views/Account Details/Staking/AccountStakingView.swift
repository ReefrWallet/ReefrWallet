//
//  AccountStakingView.swift
//  Reefr Wallet
//
//  Created by Andrey Yurkevich on 06.11.26.
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import SwiftUI

import WalletKit

/// The Staking tab's content for the account's chain.
struct AccountStakingView: View {
    let model: AccountStakingModel

    var body: some View {
        switch model {
        case let .solana(solana):
            SolanaStakingView(model: solana)
        case let .tron(tron):
            TronStakingView(model: tron)
        }
    }
}

/// The Staking tab's toolbar actions for the account's chain.
struct AccountStakingToolbarActions: View {
    let model: AccountStakingModel

    var body: some View {
        switch model {
        case let .solana(solana):
            SolanaStakingToolbarActions(model: solana)
        case let .tron(tron):
            TronStakingToolbarActions(model: tron)
        }
    }
}

/// Presents the staking sheets of the account's chain.
struct AccountStakingSheets: ViewModifier {
    let model: AccountStakingModel?

    func body(content: Content) -> some View {
        switch model {
        case let .solana(solana):
            content.sheet(item: Bindable(solana).sheet) { kind in
                SolanaStakingSheet(kind: kind, model: solana)
            }

        case let .tron(tron):
            content.sheet(item: Bindable(tron).sheet) { kind in
                TronStakingSheet(kind: kind, model: tron)
            }

        case nil:
            content
        }
    }
}

// MARK: - AccountStakingModel

/// The staking position of an account, by chain, as the tab, toolbar and sheets use it.
@MainActor
enum AccountStakingModel {
    case solana(SolanaStakingModel)
    case tron(TronStakingModel)

    /// `nil` for chains without staking.
    nonisolated static func make(account: Account, keyStore: KeyStore) -> AccountStakingModel? {
        switch account.blockchain {
        case .solana: .solana(SolanaStakingModel(account: account, keyStore: keyStore))
        case .tron: .tron(TronStakingModel(account: account, keyStore: keyStore))
        default: nil
        }
    }

    func apply(_ staking: Staking?) {
        switch self {
        case let .solana(model): model.apply(staking)
        case let .tron(model): model.apply(staking)
        }
    }

    func refresh() async {
        switch self {
        case let .solana(model): await model.refresh()
        case let .tron(model): await model.refresh()
        }
    }
}
