//
//  SuiStakingView.swift
//  Reefr Wallet
//
//  Created by Andrey Yurkevich on 08.11.26.
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import SwiftUI
import WalletKit

/// The Staking tab of a Sui account (ADR-060): the summary, then an unresolved transaction and the
/// stakes as grouped rows. One scroll view on macOS; rows of the account's list on iPhone.
struct SuiStakingView: View {
    let model: SuiStakingModel

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

private extension SuiStakingView {
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

            if model.isStaked {
                stakesSection
                    .stakingRow()
            } else if model.canSign {
                Text(.suiStakingNotStakedNote)
                    .style(.small, foreground: .secondary)
                    .padding(.horizontal, isPhone ? 16 : 12)
                    .stakingRow()
            }
        } else if let error = model.error {
            failure(error)
                .stakingRow()
        }
    }

    func summary(_ details: SuiStakingDetails) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: "\(String(localized: .tronStakingSummaryStakedLabel)) \(SuiStakingFormat.sui(details.stakedMist))")
                .style(isPhone ? .callout : .mediumHeader, foreground: isPhone ? .secondary : .primary)
                .accessibilityIdentifier("staking-staked")

            if let line = SuiStakingModel.rewardsLine(details: details, suiPrice: model.suiPrice) {
                Text(verbatim: line)
                    .style(.small, foreground: .secondary)
                    .accessibilityIdentifier("staking-rewards")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    var stakesSection: some View {
        StakingSection(
            title: .suiStakingSectionStakes,
            rows: model.positions.map { position in
                StakingRow(
                    id: position.stake.objectId,
                    leading: model.name(of: position),
                    secondary: SuiStakingModel.statusText(position),
                    trailing: SuiStakingFormat.sui(position.stake.principal)
                )
            }
        )
    }

    func unresolvedSection(_ submission: SuiPendingSubmission) -> some View {
        StakingSection(
            title: .suiStakingSectionUnresolved,
            rows: [
                StakingRow(
                    id: submission.digest,
                    leading: SuiStakingModel.kindText(submission.kind),
                    secondary: submission.digest.shortened(prefix: 4, suffix: 4),
                    trailing: String(localized: isPhone ? .solanaStakingExplorerShort : .solanaStakingViewInExplorer),
                    trailingColor: .accentColor,
                    onTrailingTap: {
                        if let url = model.explorerURL(digest: submission.digest) {
                            openURL(url)
                        }
                    }
                )
            ],
            note: String(localized: model.isUnresolvedPastValidity
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

// MARK: - SuiStakingToolbarActions

/// The Staking tab's toolbar actions: Unstake while there's a position, Stake always. Disabled
/// while a transaction's outcome is open. One pill; the toolbar shows icons or icons and text,
/// as the user chose.
struct SuiStakingToolbarActions: View {
    let model: SuiStakingModel

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
