//
//  AccountStakingView.swift
//  Reefr Wallet
//
//  Created by Andrey Yurkevich on 05.11.26.
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import SwiftUI
import WalletKit

/// The Staking tab of a Tron account (ADR-052): the summary, then Votes,
/// Resources, Unstaking and Ready to Withdraw as grouped rows. One scroll
/// view on macOS; rows of the account's list on iPhone.
struct AccountStakingView: View {
    let model: TronStakingModel

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

private extension AccountStakingView {
    @ViewBuilder
    var sections: some View {
        if let state = model.state {
            summary(state)
                .summaryRow()

            if state.votePower > 0 || !state.votes.isEmpty {
                votesSection(state)
                    .stakingRow()
            }

            resourcesSection(state)
                .stakingRow()

            if !model.pendingUnstakes().isEmpty {
                unstakingSection
                    .stakingRow()
            }

            if model.withdrawable() > 0 {
                withdrawSection(model.withdrawable())
                    .stakingRow()
            }

            if state.totalStaked == 0, model.canSign {
                Text(.tronStakingNotStakedNote)
                    .style(.small, foreground: .secondary)
                    .padding(.horizontal, isPhone ? 16 : 12)
                    .stakingRow()
            }
        } else if let error = model.error {
            failure(error)
                .stakingRow()
        } else {
            ProgressView()
                .frame(maxWidth: .infinity, minHeight: 160)
                .stakingRow()
        }
    }

    /// `Staked: N TRX` and a secondary `Rewards: N TRX (USD · APR)`, in the font and place of the
    /// other tabs' heading ("Total Value: …") so switching tabs doesn't move it.
    func summary(_ state: TronStakingState) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: "\(String(localized: .tronStakingSummaryStakedLabel)) \(TronTransactionParametersView.trx(state.totalStaked))")
                .style(isPhone ? .callout : .mediumHeader, foreground: isPhone ? .secondary : .primary)
                .accessibilityIdentifier("staking-staked")

            if state.totalStaked > 0 || state.rewards > 0 {
                Text(verbatim: rewardsLine(state))
                    .style(.small, foreground: .secondary)
                    .accessibilityIdentifier("staking-rewards")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    func votesSection(_ state: TronStakingState) -> some View {
        let unassigned = model.unassignedVotes

        return StakingSection(
            title: .tronStakingSectionVotes,
            rows: state.votes.map { vote in
                StakingRow(
                    id: vote.address.string,
                    leading: model.name(of: vote.address),
                    trailing: voteCount(vote.count)
                )
            },
            note: unassigned > 0 ? String(localized: .tronStakingVotesNotAssigned(Int(unassigned))) : nil,
            action: model.canSign && state.votePower > 0
                ? .init(title: .tronStakingVote, isProminent: unassigned > 0, perform: { model.sheet = .vote })
                : nil
        )
    }

    func resourcesSection(_ state: TronStakingState) -> some View {
        StakingSection(
            title: .tronStakingSectionResources,
            rows: [
                resourceRow(.tronTransactionParametersBandwidth, state.bandwidth),
                resourceRow(.tronTransactionParametersEnergy, state.energy)
            ]
        )
    }

    var unstakingSection: some View {
        StakingSection(
            title: .tronStakingSectionUnstaking,
            rows: model.pendingUnstakes().map { entry in
                StakingRow(
                    id: "\(entry.resource)-\(entry.expiration.timeIntervalSince1970)",
                    leading: TronTransactionParametersView.trx(entry.amount),
                    secondary: TronTransactionParametersView.resourceName(entry.resource),
                    trailing: entry.expiration.formatted(.relative(presentation: .numeric, unitsStyle: .wide)),
                    trailingColor: .secondary
                )
            },
            action: model.canSign && !model.isHardware
                ? .init(title: .tronStakingCancelAll, isProminent: false, perform: { model.sheet = .cancelUnstaking })
                : nil
        )
    }

    func withdrawSection(_ withdrawable: UInt64) -> some View {
        StakingSection(
            title: .tronStakingSectionReadyToWithdraw,
            rows: [
                StakingRow(
                    id: "withdrawable",
                    leading: TronTransactionParametersView.trx(withdrawable),
                    trailing: model.usdText(sun: withdrawable) ?? "",
                    trailingColor: .secondary
                )
            ],
            action: model.canSign
                ? .init(title: .tronStakingWithdraw, isProminent: false, perform: { model.sheet = .withdraw })
                : nil
        )
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

// MARK: - Helpers

private extension AccountStakingView {
    /// `Rewards: 0.75 TRX (0.24 US$ • 3.31% APR)`, with whichever of the parts is known.
    func rewardsLine(_ state: TronStakingState) -> String {
        let usd = model.usd(sun: state.rewards).map { $0.formatted(.currency(code: "USD")) }
        let rate = model.rewardsRate.map {
            String(localized: .tronStakingApr(($0 / 100).formatted(.percent.precision(.fractionLength(0...2)))))
        }

        let details = [usd, rate].compactMap { $0 }.joined(separator: " \(String.dot) ")
        let line = "\(String(localized: .tronStakingSummaryRewardsLabel)) \(TronTransactionParametersView.trx(state.rewards))"

        return details.isEmpty ? line : "\(line) (\(details))"
    }

    func resourceRow(_ name: LocalizedStringResource, _ usage: TronStakingState.Usage) -> StakingRow {
        let fraction = usage.limit > 0 ? Double(usage.remaining) / Double(usage.limit) : 0
        let remaining = usage.remaining.formatted(.number)
        let limit = usage.limit.formatted(.number)

        return StakingRow(
            id: String(localized: name),
            leading: String(localized: name),
            trailing: "\(remaining) / \(limit)",
            progress: fraction
        )
    }

    func voteCount(_ count: UInt64) -> String {
        String(localized: .tronStakingVoteCount(Int(count)))
    }
}

// MARK: - StakingRow

struct StakingRow: Identifiable {
    let id: String
    let leading: String
    var secondary: String?
    let trailing: String
    var trailingColor: Color = .primary
    /// 0...1 fills a bar between the two texts.
    var progress: Double?
}

// MARK: - StakingSection

/// A title above a rounded group of rows, with an optional action (and a
/// caution note) below it, as in dApp settings.
private struct StakingSection: View {
    struct Action {
        let title: LocalizedStringResource
        let isProminent: Bool
        let perform: () -> Void
    }

    let title: LocalizedStringResource
    let rows: [StakingRow]
    var note: String?
    var action: Action?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .style(isPhone ? .sectionHeader : .mediumHeader, foreground: .primary)
                .padding(.leading, isPhone ? 16 : 12)

            if !rows.isEmpty {
                // One grid per card: its columns are as wide as the widest label and value of
                // any row, so every bar has the same length and the same gap on both sides.
                Grid(horizontalSpacing: 12, verticalSpacing: 0) {
                    ForEach(rows) { row in
                        if row.id != rows.first?.id {
                            Divider()
                        }

                        gridRow(row)
                    }
                }
                .style(isPhone ? .body : .medium, foreground: nil)
                .padding(.horizontal, isPhone ? 16 : 12)
                .background(Self.cardColor, in: RoundedRectangle(cornerRadius: 10))
            }

            if note != nil || action != nil {
                HStack {
                    if let note {
                        Text(note)
                            .style(isPhone ? .caption : .small, foreground: .caution)
                            // Lines up with the title and the rows' text.
                            .padding(.leading, isPhone ? 0 : 12)
                    }

                    Spacer()

                    if let action {
                        actionButton(action)
                    }
                }
                .padding(.horizontal, isPhone ? 16 : 0)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func gridRow(_ row: StakingRow) -> some View {
        GridRow {
            HStack(spacing: 12) {
                Text(row.leading)

                if let secondary = row.secondary {
                    Text(secondary)
                        .style(foreground: .secondary)
                }
            }
            .padding(.vertical, isPhone ? 11 : 6)
            .gridColumnAlignment(.leading)

            if let progress = row.progress {
                ProgressView(value: min(max(progress, 0), 1))
                    // macOS draws a sliver of fill at 0, so an empty bar gets none.
                    .tint(progress <= 0 ? Color.clear : progress < 0.15 ? Color.caution : Color.green)
                    .frame(maxWidth: .infinity)
            } else {
                Color.clear
                    .frame(maxWidth: .infinity, maxHeight: 0)
            }

            Text(row.trailing)
                .foregroundStyle(row.trailingColor)
                .padding(.vertical, isPhone ? 11 : 6)
                .gridColumnAlignment(.trailing)
        }
    }

    @ViewBuilder
    private func actionButton(_ action: Action) -> some View {
        #if os(macOS)
        if action.isProminent {
            Button(action.title, action: action.perform)
                .buttonStyle(.borderedProminent)
        } else {
            Button(action.title, action: action.perform)
        }
        #else
        Button(action: action.perform) {
            Text(action.title)
                .fontWeight(action.isProminent ? .semibold : .regular)
        }
        #endif
    }

    private static var cardColor: Color {
        #if os(macOS)
        Color(nsColor: .controlBackgroundColor)
        #else
        Color(uiColor: .secondarySystemBackground)
        #endif
    }
}

private extension View {
    /// The summary's list row on iPhone, inset like ``AccountCountLabel``; unchanged on macOS.
    @ViewBuilder
    func summaryRow() -> some View {
        #if os(iOS)
        listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
            .listRowSeparator(.hidden)
        #else
        self
        #endif
    }

    /// One list row without separator or background on iPhone; unchanged on macOS.
    @ViewBuilder
    func stakingRow() -> some View {
        #if os(iOS)
        listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
            .listRowSeparator(.hidden)
        #else
        self
        #endif
    }
}

// MARK: - TronStakingToolbarActions

/// The Staking tab's toolbar actions: Claim while there is a stake or unclaimed rewards,
/// Unstake while there is a stake, Stake always. One pill; the toolbar shows icons or icons
/// and text, as the user chose.
struct TronStakingToolbarActions: View {
    let model: TronStakingModel

    var body: some View {
        ControlGroup {
            if model.isStaked || model.hasRewards {
                Button {
                    model.sheet = .claim
                } label: {
                    Label(.tronStakingClaim, systemImage: "arrow.down.circle")
                }
                .disabled(!model.canClaim)
                .accessibilityIdentifier("staking-claim-button")
            }

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
            .disabled(!model.canSign || model.state == nil)
            .accessibilityIdentifier("staking-stake-button")
        }
    }
}
