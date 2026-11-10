//
//  TronStakingSheet.swift
//  Reefr Wallet
//
//  Created by Andrey Yurkevich on 05.11.26.
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import BigInt
import SwiftUI
import WalletKit

/// The send/sign sheet of every staking action (ADR-052, built on
/// ``TransactionSheet`` like ``TransferView``): parameters, the Tron fees,
/// then Estimate Fees, Cancel and Next, which signs and broadcasts.
@MainActor
struct TronStakingSheet {
    let kind: TronStakingSheetKind
    let model: TronStakingModel

    @State private var amountText = ""
    @State private var balance: UInt64 = 0
    @State private var error: String?
    @State private var isErrorAlertPresented = false
    /// The amount was filled by MAX, so it follows the fee the node reports.
    @State private var isMaxSelected = false
    @State private var isPickerPresented = false
    @State private var prepareError: String?
    @State private var prepared: TronStakingTransaction?
    @State private var prepareTask: Task<Void, Never>?
    /// The send in flight, shown in the prompt popup; `nil` when idle.
    @State private var progress: TransactionProgress?
    @State private var resource = TronRawTransaction.Resource.bandwidth
    /// Representatives in the order they were picked.
    @State private var selected: [TronRepresentative] = []
    /// Vote counts typed per representative address.
    @State private var voteTexts: [String: String] = [:]

    @Environment(\.dismiss) private var dismiss

    private let service = DI.injectOrFail(TronStakingService.self)

    init(kind: TronStakingSheetKind, model: TronStakingModel) {
        self.kind = kind
        self.model = model
    }
}

// MARK: - View

extension TronStakingSheet: View {
    var body: some View {
        TransactionSheet(
            title: title,
            confirmTitle: String(localized: .commonNext),
            isConfirmEnabled: prepared != nil,
            isEstimateFeesEnabled: action != nil,
            isProcessing: progress != nil,
            onEstimateFees: onEstimateFees,
            onCancel: onCancel,
            onConfirm: onNext,
            accessibilityIds: .init(confirm: "staking-next-button", title: "staking-sheet-title")
        ) {
            parameters
        } fees: {
            TransactionFeesView(
                blockchain: model.account.blockchain,
                estimatedFees: prepared?.fee.map { Fees(nativeFeeReserve: String($0.burnedSun), tronFee: $0) },
                isEditable: false,
                isTronFeeLimitEnabled: false,
                warning: prepareError,
                fees: .constant(nil)
            )
        }
        .hardwareKeyPromptHost(progress: progress?.prompt)
        .alert(.transferTransactionFailed, isPresented: $isErrorAlertPresented) {
            Button(.commonOk) {
                isErrorAlertPresented = false
            }
        } message: {
            Text(error ?? String(localized: .transferUnknownError))
        }
        .sheet(isPresented: $isPickerPresented) {
            TronRepresentativePicker(
                representatives: model.representatives,
                selection: $selected
            )
        }
        .task {
            await loadInitialValues()
        }
        .onChange(of: action, initial: true) {
            schedulePreparation()
        }
        .onChange(of: selected) { old, new in
            onSelectionChange(from: old, to: new)
        }
        .onChange(of: resource) {
            amountText = ""
            isMaxSelected = false
        }
    }
}

// MARK: - Parameters

private extension TronStakingSheet {
    @ViewBuilder
    var parameters: some View {
        switch kind {
        case .cancelUnstaking:
            section(.tronStakingGroupCancel, note: .tronStakingNoteCancel) {
                FromRow(account: model.account)
                amountRow(model.pendingUnstakeTotal())
                valueRow(model.pendingUnstakeTotal())
            }

        case .claim:
            section(.tronStakingSummaryRewards, note: .tronStakingNoteClaim) {
                FromRow(account: model.account)
                amountRow(model.state?.rewards ?? 0)
                valueRow(model.state?.rewards ?? 0)
            }

        case .stake:
            section(.tronStakingGroupStake, note: .tronStakingNoteStake) {
                FromRow(account: model.account)
                balanceRow(String(localized: .tronStakingRowAvailable), balance)
                resourceRow
                amountField
            }

        case .unstake:
            section(.tronStakingGroupUnstake, note: .tronStakingNoteUnstake) {
                FromRow(account: model.account)
                balanceRow(String(localized: .tronStakingSummaryStaked), model.state?.staked(for: resource) ?? 0)
                resourceRow
                amountField
                resourceReductionRow
            }

        case .vote:
            ParameterSection(
                String(localized: .tronStakingVote),
                footer: String(localized: .tronStakingNoteVote(TronStakingService.maxRepresentatives))
            ) {
                FromRow(account: model.account)
                remainingVotesRow
                ForEach(selected) { representative in
                    voteField(representative)
                }

                Button(.tronStakingSelectRepresentativesButton) {
                    isPickerPresented = true

                    Task {
                        await model.refreshRepresentatives()
                    }
                }
                .accessibilityIdentifier("staking-select-representatives-button")
            }

        case .withdraw:
            section(.tronStakingGroupWithdraw, note: .tronStakingNoteWithdraw) {
                FromRow(account: model.account)
                amountRow(model.withdrawable())
                valueRow(model.withdrawable())
            }
        }
    }

    func section(
        _ title: LocalizedStringResource,
        note: LocalizedStringResource,
        @ViewBuilder rows: () -> some View
    ) -> some View {
        ParameterSection(String(localized: title), footer: String(localized: note)) {
            rows()
        }
    }

    var amountField: some View {
        ParameterRow(String(localized: .commonAmount)) {
            HStack {
                TextField("", text: amountBinding)
                    .accessibilityIdentifier("staking-amount-field")

                Button {
                    amountText = maxAmountText(burn: prepared?.fee?.burnedSun ?? 0)
                    isMaxSelected = true
                } label: {
                    Image("max16")
                }
                .buttonStyle(.borderless)
                .help(.transferParametersMaximumAmount)
            }
        }
    }

    var resourceRow: some View {
        ParameterRow(String(localized: .tronTransactionParametersResource)) {
            Picker(selection: $resource) {
                Text(.tronTransactionParametersBandwidth)
                    .tag(TronRawTransaction.Resource.bandwidth)

                Text(.tronTransactionParametersEnergy)
                    .tag(TronRawTransaction.Resource.energy)
            } label: {
                EmptyView()
            }
            .labelsHidden()
        }
    }

    /// What unstaking the typed amount costs, in the resource's own units.
    var resourceReductionRow: some View {
        let units = sun(from: amountText).flatMap { amount in
            model.state.map { $0.resourceUnits(sun: amount, resource: resource) }
        } ?? 0

        let current = resource == .energy ? model.state?.energy.limit : model.state?.bandwidth.limit
        let name = resource == .energy
            ? String(localized: .tronTransactionParametersEnergy)
            : String(localized: .tronTransactionParametersBandwidth)

        return ParameterRow(
            String(localized: .tronStakingRowResourceReduction),
            value: "−\(units.formatted(.number)) \(name)",
            subtitle: current.map { "\($0.formatted(.number)) → \((units < $0 ? $0 - units : 0).formatted(.number))" }
        )
    }

    var remainingVotesRow: some View {
        let power = model.state?.votePower ?? 0
        let assigned = selected.map { UInt64(voteTexts[$0.id] ?? "") ?? 0 }.saturatingSum
        let remaining = power > assigned ? power - assigned : 0

        return ParameterRow(
            String(localized: .tronStakingRowRemaining),
            value: String(localized: .tronStakingVotesRemaining(Int(clamping: remaining), votes: Int(clamping: power)))
        )
    }

    func voteField(_ representative: TronRepresentative) -> some View {
        ParameterRow(representative.name ?? representative.address.string.shortened(prefix: 6, suffix: 4)) {
            HStack {
                TextField("", text: voteBinding(representative))
                    .accessibilityIdentifier("staking-votes-\(representative.id)")

                if let apr = representative.apr {
                    Text(
                        .tronStakingApr(
                            (apr / 100).formatted(.percent.precision(.fractionLength(0...2)))
                        )
                    )
                    .style(.small, foreground: .secondary)
                }
            }
        }
    }

    func amountRow(_ sun: UInt64) -> some View {
        ParameterRow(String(localized: .commonAmount), value: TronTransactionParametersView.trx(sun))
    }

    func balanceRow(_ label: String, _ sun: UInt64) -> some View {
        ParameterRow(
            label,
            value: TronTransactionParametersView.trx(sun),
            subtitle: model.usdText(sun: sun)
        )
    }

    func valueRow(_ sun: UInt64) -> some View {
        ParameterRow(
            String(localized: .tronStakingRowValue),
            value: model.usdText(sun: sun) ?? ""
        )
    }
}

// MARK: - Logic

private extension TronStakingSheet {
    var title: String {
        switch kind {
        case .cancelUnstaking: String(localized: .tronStakingCancelUnstaking)
        case .claim: String(localized: .tronStakingClaimRewards)
        case .stake: String(localized: .tronStakingStake)
        case .unstake: String(localized: .tronStakingUnstake)
        case .vote: String(localized: .tronStakingVote)
        case .withdraw: String(localized: .tronStakingWithdraw)
        }
    }

    /// The action the inputs describe; `nil` until they are complete.
    var action: TronStakingAction? {
        switch kind {
        case .cancelUnstaking:
            return .cancelUnstaking
        case .claim:
            return .claim
        case .stake:
            return sun(from: amountText).map { .stake(sun: $0, resource: resource) }
        case .unstake:
            return sun(from: amountText).map { .unstake(sun: $0, resource: resource) }
        case .vote:
            return voteAction
        case .withdraw:
            return .withdraw
        }
    }

    /// The vote the typed counts describe. A zero count leaves its representative out on purpose;
    /// a count that is empty, malformed or overflows rejects the whole vote rather than dropping it.
    var voteAction: TronStakingAction? {
        var votes: [TronRawTransaction.Vote] = []

        for representative in selected {
            guard let count = UInt64(voteTexts[representative.id] ?? "") else {
                return nil
            }

            if count > 0 {
                votes.append(TronRawTransaction.Vote(address: representative.address, count: count))
            }
        }

        return votes.isEmpty ? nil : .vote(votes)
    }

    /// TRX typed as `text`, in SUN; `nil` unless it is a positive amount of whole SUN.
    func sun(from text: String) -> UInt64? {
        let blockchain = model.account.blockchain
        let token = Token(address: nil, blockchain: blockchain, tokenInfo: blockchain.nativeToken)

        return (try? token.smallestUnitAmount(from: text)).flatMap { UInt64(exactly: $0) }
    }

    /// Typing replaces a MAX amount with the user's own.
    var amountBinding: Binding<String> {
        Binding(
            get: { amountText },
            set: { text in
                amountText = text
                isMaxSelected = false
            }
        )
    }

    /// All of the balance (staking) or of this resource's stake (unstaking), less `burn`, the TRX
    /// the fee estimate says a stake burns.
    func maxAmountText(burn: UInt64) -> String {
        let sun: UInt64

        switch kind {
        case .stake:
            sun = balance > burn ? balance - burn : 0
        case .unstake:
            sun = model.state?.staked(for: resource) ?? 0
        default:
            sun = 0
        }

        return "\(Decimal(sun) / Decimal(1_000_000))"
    }

    func voteBinding(_ representative: TronRepresentative) -> Binding<String> {
        Binding(
            get: { voteTexts[representative.id] ?? "" },
            set: { voteTexts[representative.id] = $0 }
        )
    }

    func loadInitialValues() async {
        if kind == .vote {
            await model.refreshRepresentatives()
        }

        if let state = model.state {
            // Unstake from whichever resource has a stake.
            if kind == .unstake, state.staked(for: .bandwidth) == 0, state.staked(for: .energy) > 0 {
                resource = .energy
            }

            if kind == .vote, selected.isEmpty {
                selected = state.votes.map { vote in
                    model.representatives.first { $0.address == vote.address }
                        ?? TronRepresentative(address: vote.address, voteCount: 0)
                }

                voteTexts = Dictionary(uniqueKeysWithValues: state.votes.map { ($0.address.string, "\($0.count)") })
            }
        }

        balance = (try? await service.availableBalance(for: model.account)) ?? 0
    }

    /// Representatives that have no votes yet start with the votes still unassigned;
    /// the ones restored from the account's existing votes keep theirs.
    func onSelectionChange(from old: [TronRepresentative], to new: [TronRepresentative]) {
        let power = model.state?.votePower ?? 0
        var assigned = new.map { UInt64(voteTexts[$0.id] ?? "") ?? 0 }.saturatingSum

        for representative in new
        where !old.contains(where: { $0.id == representative.id }) && voteTexts[representative.id] == nil {
            let remaining = power > assigned ? power - assigned : 0
            voteTexts[representative.id] = "\(remaining)"
            assigned = [assigned, remaining].saturatingSum
        }

        for representative in old where !new.contains(where: { $0.id == representative.id }) {
            voteTexts[representative.id] = nil
        }
    }

    func onCancel() {
        dismiss()
    }

    // MARK: Preparation

    func onEstimateFees() {
        prepareTask?.cancel()
        prepareTask = Task {
            await prepare()
        }
    }

    /// Builds the transaction once the inputs settle; `nil` action clears it.
    func schedulePreparation() {
        prepareTask?.cancel()
        prepared = nil
        prepareError = nil

        guard action != nil else {
            return
        }

        prepareTask = Task {
            do {
                try await Task.sleep(for: .seconds(0.5))
            } catch {
                return  // cancelled during the delay
            }

            await prepare()
        }
    }

    func prepare() async {
        guard let action else {
            return
        }

        do {
            let transaction = try await service.prepare(action, account: model.account)

            guard self.action == action else {
                return
            }

            prepared = transaction
            prepareError = nil

            // MAX was chosen before the fee was known: leave room for its burn.
            if kind == .stake, isMaxSelected, let burn = transaction.fee?.burnedSun {
                let reserved = maxAmountText(burn: burn)

                if reserved != amountText {
                    amountText = reserved
                }
            }
        } catch {
            guard !Task.isCancelled, self.action == action else {
                return
            }

            prepared = nil
            prepareError = error.localizedDescription
        }
    }

    // MARK: Sending

    func onNext() {
        guard let action = prepared?.action else {
            return
        }

        Task { @MainActor in
            do {
                try await $progress.track {
                    try await send(action)
                }

                dismiss()
            } catch {
                self.error = error.localizedDescription
                isErrorAlertPresented = true
            }
        }
    }

    /// Builds `action` afresh and sends it: a transaction prepared while the sheet was open
    /// expires about a minute after the node built it.
    func send(_ action: TronStakingAction) async throws {
        let account = model.account
        let transaction = try await service.prepare(action, account: account)

        if model.isHardware {
            progress = .signing
        }

        let signature = try await service.sign(transaction, account: account)

        progress = .sending
        let hash = try await service.broadcast(transaction, signature: signature, account: account)
        printDebug(hash)

        try await service.waitForConfirmation(hash, account: account)
    }
} // swiftlint:disable:this file_length
