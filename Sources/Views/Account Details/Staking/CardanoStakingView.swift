//
//  CardanoStakingView.swift
//  Reefr Wallet
//
//  Created by Andrey Yurkevich on 08.11.26.
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import SwiftUI
import WalletKit

/// The Staking tab of a Cardano account (ADR-059): the summary, then a two-step workflow waiting to
/// continue, an unresolved transaction, and the Delegation and Rewards groups. One scroll view on
/// macOS; rows of the account's list on iPhone.
struct CardanoStakingView: View {
    let model: CardanoStakingModel

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

private extension CardanoStakingView {
    @ViewBuilder
    var sections: some View {
        if let details = model.details {
            summary(details)
                .summaryRow()

            if let message = model.error {
                notice(String(localized: .cardanoStakingNoticeRefreshFailed), help: message)
                    .stakingRow()
            }

            if let workflow = model.workflow {
                workflowSection(workflow, details: details)
                    .stakingRow()
            }

            if let unresolved = model.unresolved {
                unresolvedSection(unresolved)
                    .stakingRow()
            }

            if details.registered {
                delegationSection(details)
                    .stakingRow()

                rewardsSection(details)
                    .stakingRow()
            } else if model.canSign {
                Text(.cardanoStakingNotStakedNote)
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

    func summary(_ details: CardanoStakingDetails) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: "\(String(localized: .cardanoStakingSummaryDelegated)) \(CardanoStakingFormat.ada(model.delegatedStake))")
                .style(isPhone ? .callout : .mediumHeader, foreground: isPhone ? .secondary : .primary)
                .accessibilityIdentifier("staking-staked")

            if let line = model.timingText() {
                Text(verbatim: line)
                    .style(.small, foreground: .secondary)
                    .accessibilityIdentifier("staking-timing")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Delegated stake is display only: another payment key under the same stake key counts too.
    func delegationSection(_ details: CardanoStakingDetails) -> some View {
        let pool = details.pool
        let canChange = model.canChange
        let changeDRep = StakingSection.Action(
            title: .cardanoStakingChangeDrep,
            isProminent: false,
            isDisabled: !canChange,
            perform: { model.sheet = .changeDRep }
        )

        let changePool = StakingSection.Action(
            title: pool == nil ? .cardanoStakingChoosePool : .cardanoStakingChangePool,
            isProminent: false,
            isDisabled: !canChange,
            perform: { model.sheet = .changePool }
        )

        return StakingSection(
            title: .cardanoStakingSectionDelegation,
            rows: [
                StakingRow(
                    id: "delegated",
                    leading: String(localized: .cardanoStakingRowDelegatedStake),
                    secondary: String(localized: .cardanoStakingDisplayOnly),
                    trailing: CardanoStakingFormat.ada(model.delegatedStake)
                ),
                StakingRow(
                    id: "pool",
                    leading: String(localized: .cardanoStakingRowPool),
                    secondary: pool.map(model.poolName) ?? String(localized: .cardanoStakingNotDelegated),
                    trailing: pool.map(CardanoStakingModel.marginText) ?? "",
                    trailingColor: .secondary
                ),
                StakingRow(
                    id: "drep",
                    leading: String(localized: .cardanoStakingRowDrep),
                    secondary: details.drep.map { model.drepName($0, name: details.drepName) }
                        ?? String(localized: .cardanoStakingNoDrep),
                    trailing: ""
                )
            ],
            action: model.canSign ? changeDRep : nil,
            secondaryAction: model.canSign ? changePool : nil
        )
    }

    func rewardsSection(_ details: CardanoStakingDetails) -> some View {
        var rows = [
            StakingRow(
                id: "rewards",
                leading: String(localized: .cardanoStakingRowRewardsAvailable),
                secondary: model.usdText(lovelace: model.rewards),
                trailing: CardanoStakingFormat.ada(model.rewards)
            ),
            StakingRow(
                id: "earned",
                leading: String(localized: .cardanoStakingRowTotalEarned),
                trailing: CardanoStakingFormat.ada(details.totalEarned)
            )
        ]

        if let reward = CardanoStakingModel.rewardRow(details.latestReward) {
            rows.append(StakingRow(
                id: "latest",
                leading: reward.epoch,
                secondary: String(localized: .cardanoStakingLatestReward),
                trailing: reward.amount
            ))
        }

        return StakingSection(
            title: .cardanoStakingSectionRewards,
            rows: rows,
            action: model.canSign
                ? .init(title: .tronStakingWithdraw, isProminent: false, isDisabled: !model.canWithdraw, perform: {
                    model.sheet = .withdraw
                })
                : nil
        )
    }

    /// A withdrawal or deregistration waiting for its vote delegation, or for its final step.
    func workflowSection(_ workflow: CardanoStakingWorkflow, details: CardanoStakingDetails) -> some View {
        let isWithdraw = workflow.intent == .withdraw

        return StakingSection(
            title: isWithdraw ? .cardanoStakingSectionContinueWithdrawal : .cardanoStakingSectionContinueStopStaking,
            rows: [
                StakingRow(
                    id: "workflow",
                    leading: String(
                        localized: isWithdraw ? .cardanoStakingActionWithdraw : .cardanoStakingActionStopStaking
                    ),
                    secondary: stepText(workflow.phase),
                    trailing: isWithdraw ? CardanoStakingFormat.ada(model.rewards) : "",
                    trailingColor: .secondary
                )
            ],
            note: workflowNote(workflow.phase),
            action: .init(
                title: .cardanoStakingContinue,
                isProminent: true,
                isDisabled: !model.canContinueWorkflow,
                perform: { model.sheet = CardanoStakingSheetKind(workflow.intent) }
            ),
            secondaryAction: .init(title: .cardanoStakingCancel, isProminent: false, perform: {
                Task {
                    await model.cancelWorkflow()
                }
            })
        )
    }

    func stepText(_ phase: CardanoStakingWorkflow.Phase) -> String {
        switch phase {
        case .needsVoteDelegation, .voteDelegationPending: String(localized: .cardanoStakingStepOne)
        case .finalStepPending, .readyForFinalStep: String(localized: .cardanoStakingStepTwo)
        }
    }

    func workflowNote(_ phase: CardanoStakingWorkflow.Phase) -> String {
        switch phase {
        case let .needsVoteDelegation(notice):
            notice.map(noticeText) ?? String(localized: .cardanoStakingNoteStepOneWaiting)
        case .voteDelegationPending:
            String(localized: .cardanoStakingNoteStepOnePending)
        case let .readyForFinalStep(notice):
            notice.map(noticeText) ?? String(localized: .cardanoStakingNoteStepTwoReady)
        case .finalStepPending:
            String(localized: .cardanoStakingNoteStepTwoPending)
        }
    }

    func noticeText(_ notice: CardanoStakingWorkflow.Notice) -> String {
        switch notice {
        case .expired: String(localized: .cardanoStakingNoticeStepExpired)
        case .failed: String(localized: .cardanoStakingNoticeStepFailed)
        }
    }

    func unresolvedSection(_ submission: CardanoPendingSubmission) -> some View {
        StakingSection(
            title: .solanaStakingSectionUnresolved,
            rows: [
                StakingRow(
                    id: submission.hash,
                    leading: String(localized: .cardanoStakingTransaction),
                    secondary: submission.hash.shortened(prefix: 4, suffix: 4),
                    trailing: String(localized: isPhone ? .solanaStakingExplorerShort : .solanaStakingViewInExplorer),
                    trailingColor: .accentColor,
                    onTrailingTap: {
                        if let url = model.explorerURL(hash: submission.hash) {
                            openURL(url)
                        }
                    }
                )
            ],
            note: String(localized: .cardanoStakingNoticeSubmitted),
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

// MARK: - CardanoStakingToolbarActions

/// The Staking tab's toolbar actions: Stop Staking and Stake, each disabled when it doesn't apply
/// or while a transaction or workflow is open. One pill; the toolbar shows icons or icons and
/// text, as the user chose.
struct CardanoStakingToolbarActions: View {
    let model: CardanoStakingModel

    var body: some View {
        ControlGroup {
            Button {
                model.sheet = .stopStaking
            } label: {
                Label(.cardanoStakingStopStaking, systemImage: "lock.open")
            }
            .disabled(!model.canStopStaking)
            .accessibilityIdentifier("staking-stop-button")

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
