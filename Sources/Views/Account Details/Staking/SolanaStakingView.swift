//
//  SolanaStakingView.swift
//  Reefr Wallet
//
//  Created by Andrey Yurkevich on 06.11.26.
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import SwiftUI
import WalletKit

/// The Staking tab of a Solana account (ADR-054): the summary, then an unresolved transaction,
/// Stake Accounts, Unstaking and Ready to Withdraw as grouped rows. One scroll view on macOS;
/// rows of the account's list on iPhone.
struct SolanaStakingView: View {
    let model: SolanaStakingModel

    @Environment(\.openURL) private var openURL

    var body: some View {
        #if os(iOS)
        sections
        #else
        ScrollView {
            // No top padding: the summary lands where the other tabs' heading does.
            VStack(alignment: .leading, spacing: 20) {
                sections
            }
            .padding([.bottom, .horizontal])
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        #endif
    }
}

// MARK: - Sections

private extension SolanaStakingView {
    @ViewBuilder
    var sections: some View {
        if let details = model.details {
            summary(details)
                .summaryRow()

            if let message = model.error {
                notice(String(localized: .solanaStakingNoticeRefreshFailed), help: message)
                    .stakingRow()
            }

            if let unresolved = model.unresolved {
                unresolvedSection(unresolved)
                    .stakingRow()
            }

            if !model.stakeAccounts.isEmpty {
                stakeAccountsSection
                    .stakingRow()
            }

            if model.isDiscoveryDegraded {
                notice(String(localized: .solanaStakingNoticeDegraded))
                    .stakingRow()
            }

            if !model.unstaking.isEmpty {
                unstakingSection
                    .stakingRow()
            }

            if !model.withdrawable.isEmpty {
                withdrawSection
                    .stakingRow()
            }

            if details.positions.isEmpty, model.canSign {
                Text(.solanaStakingNotStakedNote)
                    .style(.small, foreground: .secondary)
                    .padding(.horizontal, isPhone ? 16 : 12)
                    .stakingRow()
            }
        } else if let error = model.error {
            failure(error)
                .stakingRow()
        }
    }

    func summary(_ details: SolanaStakingDetails) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: "\(String(localized: .tronStakingSummaryStakedLabel)) \(SolanaStakingFormat.sol(details.stakedLamports))")
                .style(isPhone ? .callout : .mediumHeader, foreground: isPhone ? .secondary : .primary)
                .accessibilityIdentifier("staking-staked")

            if let line = SolanaStakingModel.rewardsLine(details: details, solPrice: model.solPrice) {
                Text(verbatim: line)
                    .style(.small, foreground: .secondary)
                    .accessibilityIdentifier("staking-rewards")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    var stakeAccountsSection: some View {
        StakingSection(
            title: .solanaStakingSectionStakeAccounts,
            rows: model.stakeAccounts.map { position in
                StakingRow(
                    id: position.account.address,
                    leading: model.name(of: position.account.delegation?.voter),
                    secondary: model.statusText(position),
                    trailing: SolanaStakingFormat.sol(position.account.delegation?.stake ?? position.account.lamports)
                )
            }
        )
    }

    var unstakingSection: some View {
        StakingSection(
            title: .tronStakingSectionUnstaking,
            rows: model.unstaking.map { position in
                StakingRow(
                    id: position.account.address,
                    leading: model.name(of: position.account.delegation?.voter),
                    secondary: model.nextEpochText() ?? model.statusText(position),
                    trailing: SolanaStakingFormat.sol(position.account.delegation?.stake ?? position.account.lamports)
                )
            }
        )
    }

    var withdrawSection: some View {
        StakingSection(
            title: .tronStakingSectionReadyToWithdraw,
            rows: [
                StakingRow(
                    id: "withdrawable",
                    leading: SolanaStakingFormat.sol(model.withdrawableLamports),
                    trailing: model.usdText(lamports: model.withdrawableLamports) ?? "",
                    trailingColor: .secondary
                )
            ],
            action: model.canSign
                ? .init(title: .tronStakingWithdraw, isProminent: false, perform: { model.sheet = .withdraw })
                : nil
        )
        .disabled(!model.canWithdraw && model.canSign)
    }

    func unresolvedSection(_ submission: SolanaPendingSubmission) -> some View {
        StakingSection(
            title: .solanaStakingSectionUnresolved,
            rows: [
                StakingRow(
                    id: submission.signature,
                    leading: SolanaStakingModel.actionText(submission.action),
                    secondary: submission.signature.shortened(prefix: 4, suffix: 4),
                    trailing: String(localized: isPhone ? .solanaStakingExplorerShort : .solanaStakingViewInExplorer),
                    trailingColor: .accentColor,
                    onTrailingTap: {
                        if let url = model.explorerURL(signature: submission.signature) {
                            openURL(url)
                        }
                    }
                )
            ],
            note: String(localized: submission.isPastValidity
                ? .solanaStakingNoticeOutcomeUnknown
                : .solanaStakingNoticeSubmitted),
            action: .init(title: .solanaStakingCheckAgain, isProminent: true, perform: {
                Task {
                    await model.checkAgain()
                }
            })
        )
    }

    /// A caution note with Retry, per the Penpot `Section Action` `Prominent` control.
    func notice(_ text: String, help: String? = nil) -> some View {
        StakingSection(
            rows: [],
            note: text,
            action: .init(title: .tronStakingRetry, isProminent: true, perform: {
                Task {
                    await model.refresh()
                }
            })
        )
        .help(help ?? "")
    }

    func failure(_ message: String) -> some View {
        VStack(spacing: 12) {
            Text(.tronStakingLoadFailed(message))
                .style(.medium, foreground: .secondary)
                .multilineTextAlignment(.center)

            Button(.tronStakingRetry) {
                Task {
                    await model.refresh()
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: 160)
    }
}

// MARK: - SolanaStakingToolbarActions

/// The Staking tab's toolbar actions: Unstake while there's a position, Stake always. Disabled
/// while a transaction's outcome is open. One pill; the toolbar shows icons or icons and text,
/// as the user chose.
struct SolanaStakingToolbarActions: View {
    let model: SolanaStakingModel

    var body: some View {
        ControlGroup {
            if model.isStaked {
                Button {
                    model.sheet = .unstake
                } label: {
                    Label(.tronStakingUnstake, systemImage: "lock.open")
                }
                .disabled(!model.canUnstake)
                .accessibilityIdentifier("staking-unstake-button")
            }

            Button {
                model.sheet = .stake
            } label: {
                Label(.tronStakingStake, systemImage: "lock")
            }
            .disabled(!model.canStake)
            .accessibilityIdentifier("staking-stake-button")
        }
    }
}
