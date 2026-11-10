//
//  CardanoStakingSheet.swift
//  Reefr Wallet
//
//  Created by Andrey Yurkevich on 08.11.26.
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import BigInt
import SwiftUI
import WalletKit

// MARK: - CardanoStakingSheetOutcome

/// What the sheet shows once it has stopped asking for input (the Penpot `Outcome` usecase).
enum CardanoStakingSheetOutcome: Equatable {
    case expired(hash: String)
    /// It expired waiting for the signature, so nothing was sent.
    case signAgain
    case submitted(hash: String)

    var hash: String? {
        switch self {
        case let .expired(hash), let .submitted(hash): hash
        case .signAgain: nil
        }
    }

    var isUnresolved: Bool {
        if case .submitted = self {
            true
        } else {
            false
        }
    }
}

/// Where a withdrawal or deregistration is: one transaction, or two when a DRep is needed first.
enum CardanoStakingStage: Equatable {
    case finalStep
    case single
    case voteDelegation
}

// MARK: - CardanoStakingSheet

/// The send/sign sheet of every Cardano staking action (ADR-059, built on ``TransactionSheet``):
/// parameters and read-only fees, then Estimate Fees, Cancel and Next, which signs, records and
/// broadcasts, or the outcome of doing that.
@MainActor
struct CardanoStakingSheet {
    let kind: CardanoStakingSheetKind
    let model: CardanoStakingModel

    @State private var balance: BigUInt = 0
    @State private var drep: CardanoDRepChoice?
    @State private var error: String?
    @State private var isDRepPickerPresented = false
    @State private var isErrorAlertPresented = false
    @State private var isPoolPickerPresented = false
    @State private var outcome: CardanoStakingSheetOutcome?
    @State private var pool: CardanoPool?
    @State private var prepareError: String?
    @State private var prepared: CardanoPreparedStaking?
    @State private var prepareTask: Task<Void, Never>?
    /// The send in flight, shown in the prompt popup; `nil` when idle.
    @State private var progress: TransactionProgress?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    private let service = DI.injectOrFail(CardanoStakingService.self)

    init(kind: CardanoStakingSheetKind, model: CardanoStakingModel) {
        self.kind = kind
        self.model = model
    }
}

// MARK: - View

extension CardanoStakingSheet: View {
    var body: some View {
        TransactionSheet(
            title: title,
            confirmTitle: confirmTitle,
            isConfirmEnabled: isConfirmEnabled,
            isEstimateFeesEnabled: isEstimateEnabled,
            isProcessing: progress != nil,
            cancelTitle: cancelTitle,
            isCancelHidden: outcome?.isUnresolved == true,
            estimateTitle: estimateTitle,
            onEstimateFees: estimateAction,
            onCancel: onCancel,
            onConfirm: onConfirm,
            accessibilityIds: .init(confirm: "staking-next-button", title: "staking-sheet-title")
        ) {
            if let outcome {
                outcomeSection(outcome)
            } else {
                parameters
            }
        } fees: {
            if outcome == nil {
                TransactionFeesView(
                    blockchain: model.account.blockchain,
                    estimatedFees: estimatedFees,
                    isEditable: false,
                    cardanoStaking: feeLines,
                    warning: prepareError,
                    fees: .constant(nil)
                )
            }
        }
        .hardwareKeyPromptHost(progress: progress?.prompt)
        .alert(.transferTransactionFailed, isPresented: $isErrorAlertPresented) {
            Button(.commonOk) {
                isErrorAlertPresented = false
            }
        } message: {
            Text(verbatim: error ?? String(localized: .transferUnknownError))
        }
        .sheet(isPresented: $isPoolPickerPresented) {
            CardanoPoolPicker(account: model.account, selection: $pool)
        }
        .sheet(isPresented: $isDRepPickerPresented) {
            CardanoDRepPicker(account: model.account, isOptional: kind == .stake, selection: $drep)
        }
        .task {
            await loadInitialValues()
        }
        .task(id: outcome?.hash) {
            await followOutcome()
        }
        .onChange(of: action, initial: true) {
            schedulePreparation()
        }
    }
}

// MARK: - Parameters

private extension CardanoStakingSheet {
    @ViewBuilder
    var parameters: some View {
        ParameterSection(groupTitle, footer: note, footerColor: noticeText == nil ? .secondary : .caution) {
            FromRow(account: model.account)

            switch kind {
            case .stake:
                ParameterRow(
                    String(localized: .tronStakingRowAvailable),
                    value: CardanoStakingFormat.ada(balance),
                    subtitle: model.usdText(lovelace: balance)
                )

                poolRow(label: String(localized: .cardanoStakingRowPool))
                ParameterRow(String(localized: .cardanoStakingRowDeposit), value: depositText)

                drepRow(
                    label: String(localized: .cardanoStakingRowDrepOptional),
                    placeholder: String(localized: .cardanoStakingSkipForNow)
                )

            case .changePool:
                ParameterRow(String(localized: .cardanoStakingRowCurrentPool), value: currentPoolText)
                poolRow(label: String(localized: .cardanoStakingRowNewPool))

            case .changeDRep:
                ParameterRow(String(localized: .cardanoStakingRowCurrentDrep), value: currentDRepText)
                drepRow(
                    label: String(localized: .cardanoStakingRowNewDrep),
                    placeholder: String(localized: .cardanoStakingChooseDrep)
                )

            case .withdraw:
                ParameterRow(
                    String(localized: .cardanoStakingRowRewards),
                    value: CardanoStakingFormat.ada(model.rewards),
                    subtitle: model.usdText(lovelace: model.rewards)
                )

                stageDRepRow

            case .stopStaking:
                ParameterRow(
                    String(localized: .cardanoStakingRowRewardsWithdrawn),
                    value: CardanoStakingFormat.ada(model.rewards),
                    subtitle: model.usdText(lovelace: model.rewards)
                )

                ParameterRow(
                    String(localized: .cardanoStakingRowDepositRefunded),
                    value: model.details?.refundDeposit.map(CardanoStakingFormat.ada) ?? ""
                )

                if stage == .voteDelegation {
                    stageDRepRow
                }
            }
        }
    }

    /// A DRep to choose in step 1, or the one that's delegated.
    @ViewBuilder
    var stageDRepRow: some View {
        if stage == .voteDelegation {
            drepRow(
                label: String(localized: .cardanoStakingRowDrep),
                placeholder: String(localized: .cardanoStakingChooseDrep)
            )
        } else {
            ParameterRow(String(localized: .cardanoStakingRowDrep), value: currentDRepText)
        }
    }

    func poolRow(label: String) -> some View {
        ParameterRow(label) {
            Button {
                isPoolPickerPresented = true
            } label: {
                HStack {
                    Text(verbatim: pool.map(Self.name) ?? String(localized: .cardanoStakingSelectPool))

                    Spacer()

                    Image(systemName: "chevron.up.chevron.down")
                        .imageScale(.small)
                }
            }
            .accessibilityIdentifier("staking-pool-button")
        }
    }

    func drepRow(label: String, placeholder: String) -> some View {
        ParameterRow(label) {
            Button {
                isDRepPickerPresented = true
            } label: {
                HStack {
                    Text(verbatim: drep?.title ?? placeholder)

                    Spacer()

                    Image(systemName: "chevron.up.chevron.down")
                        .imageScale(.small)
                }
            }
            .accessibilityIdentifier("staking-drep-button")
        }
    }

    func outcomeSection(_ outcome: CardanoStakingSheetOutcome) -> some View {
        ParameterSection(String(localized: .cardanoStakingTransaction), footer: outcomeNote(outcome)) {
            FromRow(account: model.account)

            if let action {
                ParameterRow(
                    String(localized: .solanaStakingRowAction),
                    value: CardanoStakingModel.actionText(action, poolName: pool.map(Self.name))
                )
            }

            ParameterRow(String(localized: .solanaStakingRowStatus), value: outcomeStatus(outcome))

            if let hash = outcome.hash {
                ParameterRow(String(localized: .cardanoStakingTransaction), value: hash.shortened(prefix: 4, suffix: 4))
            }
        }
    }
}

// MARK: - Logic

private extension CardanoStakingSheet {
    var title: String {
        switch kind {
        case .changeDRep: String(localized: .cardanoStakingChangeDrep)
        case .changePool: String(localized: .cardanoStakingChangePool)
        case .stake: String(localized: .tronStakingStake)
        case .stopStaking: String(localized: .cardanoStakingActionStopStaking)
        case .withdraw: String(localized: .cardanoStakingActionWithdraw)
        }
    }

    /// The group header: the action, and which of two steps it is.
    var groupTitle: String {
        switch stage {
        case .single: kind == .stake ? String(localized: .cardanoStakingGroupStake) : title
        case .voteDelegation: String(localized: .cardanoStakingGroupStep(title, 1))
        case .finalStep: String(localized: .cardanoStakingGroupStep(title, 2))
        }
    }

    var confirmTitle: String {
        switch outcome {
        case nil: String(localized: .commonNext)
        case .expired: String(localized: .solanaStakingTryAgain)
        case .signAgain: String(localized: .solanaStakingSignAgain)
        case .submitted: String(localized: .solanaStakingClose)
        }
    }

    var isConfirmEnabled: Bool {
        outcome != nil || prepared != nil
    }

    var isEstimateEnabled: Bool {
        outcome != nil || action != nil
    }

    var cancelTitle: String? {
        switch outcome {
        case nil, .signAgain: nil
        default: String(localized: .solanaStakingClose)
        }
    }

    var estimateTitle: String? {
        outcome == nil ? nil : String(localized: .solanaStakingViewInExplorer)
    }

    /// Estimate Fees before sending; afterwards the explorer link, unless nothing landed.
    var estimateAction: (() -> Void)? {
        switch outcome {
        case nil, .submitted: onEstimateFees
        case .expired, .signAgain: nil
        }
    }

    var estimatedFees: Fees? {
        prepared.map { Fees(nativeFeeReserve: String($0.fee)) }
    }

    var feeLines: CardanoStakingFeeLines? {
        prepared.map { CardanoStakingFeeLines(deposit: $0.deposit, refund: $0.refund + $0.withdrawal) }
    }

    /// A withdrawal or deregistration with no DRep delegated needs a vote delegation first.
    var stage: CardanoStakingStage {
        guard let intent = kind.intent else {
            return .single
        }

        if let workflow = model.workflow, workflow.intent == intent {
            switch workflow.phase {
            case .needsVoteDelegation: return .voteDelegation
            case .readyForFinalStep: return .finalStep
            case .finalStepPending, .voteDelegationPending: return .single
            }
        }

        let needsDRep = model.details?.drep == nil && model.rewards > 0

        return needsDRep ? .voteDelegation : .single
    }

    static func name(_ pool: CardanoPool) -> String {
        CardanoStakingModel.poolName(ticker: pool.ticker, name: pool.name, poolId: pool.poolId)
    }

    var depositText: String {
        prepared.map { String(localized: .cardanoStakingDepositRefundable(CardanoStakingFormat.ada($0.deposit))) } ?? ""
    }

    var currentPoolText: String {
        model.details?.pool.map(model.poolName) ?? String(localized: .cardanoStakingNotDelegated)
    }

    var currentDRepText: String {
        guard let details = model.details, let current = details.drep else {
            return drep?.title ?? String(localized: .cardanoStakingNoDrep)
        }

        return model.drepName(current, name: details.drepName)
    }

    var noticeText: String? {
        guard let phase = model.workflow?.phase else {
            return nil
        }

        switch phase {
        case .needsVoteDelegation(.expired?), .readyForFinalStep(.expired?):
            return String(localized: .cardanoStakingNoticeStepExpired)
        case .needsVoteDelegation(.failed?), .readyForFinalStep(.failed?):
            return String(localized: .cardanoStakingNoticeStepFailed)
        default: return nil
        }
    }

    var note: String {
        if let noticeText {
            return noticeText
        }

        switch (kind, stage) {
        case (.stake, _): return String(localized: .cardanoStakingNoteStake)
        case (.changePool, _): return String(localized: .cardanoStakingNoteChangePool)
        case (.changeDRep, _): return String(localized: .cardanoStakingNoteChangeDrep)
        case (.withdraw, .single): return String(localized: .cardanoStakingNoteWithdraw)
        case (.withdraw, .voteDelegation): return String(localized: .cardanoStakingNoteWithdrawStepOne)
        case (.withdraw, .finalStep): return String(localized: .cardanoStakingNoteWithdrawStepTwo)
        case (.stopStaking, .single): return String(localized: .cardanoStakingNoteStopStaking)
        case (.stopStaking, .voteDelegation): return String(localized: .cardanoStakingNoteStopStakingStepOne)
        case (.stopStaking, .finalStep): return String(localized: .cardanoStakingNoteStopStakingStepTwo)
        }
    }

    func outcomeStatus(_ outcome: CardanoStakingSheetOutcome) -> String {
        switch outcome {
        case .expired: String(localized: .solanaStakingOutcomeExpired)
        case .signAgain: String(localized: .solanaStakingOutcomeSignAgain)
        case .submitted: String(localized: .solanaStakingOutcomeSubmitted)
        }
    }

    func outcomeNote(_ outcome: CardanoStakingSheetOutcome) -> String {
        switch outcome {
        case .expired: String(localized: .cardanoStakingOutcomeExpiredNote)
        case .signAgain: String(localized: .cardanoStakingOutcomeSignAgainNote)
        case .submitted: String(localized: .cardanoStakingOutcomeSubmittedNote)
        }
    }

    /// The action the inputs describe; `nil` until they are complete.
    var action: CardanoStakingAction? {
        switch kind {
        case .stake:
            return pool.map { .stake(pool: $0.poolId, drep: drep?.drep) }
        case .changePool:
            return pool.map { .changePool($0.poolId) }
        case .changeDRep:
            return drep.map { .changeDRep($0.drep) }
        case .withdraw, .stopStaking:
            switch stage {
            case .voteDelegation: return drep.map { .changeDRep($0.drep) }
            case .single, .finalStep: return kind == .withdraw ? .withdraw : .stopStaking
            }
        }
    }

    var role: CardanoStepRole {
        switch stage {
        case .single:
            return .standalone
        case .voteDelegation:
            guard let intent = kind.intent, let drep else {
                return .standalone
            }

            return .voteDelegation(intent: intent, drep: drep.drep)
        case .finalStep:
            return .finalStep
        }
    }

    func loadInitialValues() async {
        balance = (try? await service.availableBalance(for: model.account)) ?? 0

        if let workflow = model.workflow, workflow.intent == kind.intent, case .needsVoteDelegation = workflow.phase {
            drep = CardanoDRepChoice(drep: workflow.drep, name: model.details?.drepName)
        }
    }

    func onCancel() {
        dismiss()
    }

    /// While the outcome is open, Estimate Fees is the explorer link.
    func onEstimateFees() {
        if let hash = outcome?.hash {
            if let url = model.explorerURL(hash: hash) {
                openURL(url)
            }

            return
        }

        prepareTask?.cancel()
        prepareTask = Task {
            await prepare()
        }
    }

    func onConfirm() {
        switch outcome {
        case nil:
            if let action, prepared != nil {
                send(action)
            }

        case .signAgain:
            if let action {
                outcome = nil
                send(action)
            }

        case .expired:
            outcome = nil
            schedulePreparation()
        case .submitted:
            dismiss()
        }
    }

    // MARK: Preparation

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
            let transaction = try await service.prepare(action, account: model.account, signer: model.signer)

            guard self.action == action else {
                return
            }

            prepared = transaction
            prepareError = nil
        } catch {
            guard !Task.isCancelled, self.action == action else {
                return
            }

            prepared = nil
            prepareError = error.localizedDescription
        }
    }

    // MARK: Sending

    func send(_ action: CardanoStakingAction) {
        Task { @MainActor in
            do {
                try await $progress.track {
                    try await run(action)
                }

                if outcome == nil {
                    dismiss()
                }
            } catch CardanoStakingFailure.expiredBeforeSending {
                outcome = .signAgain
            } catch {
                self.error = error.localizedDescription
                isErrorAlertPresented = true
            }
        }
    }

    /// Rebuilds just before signing, then sends what was signed.
    func run(_ action: CardanoStakingAction) async throws {
        let account = model.account
        let transaction = try await service.prepare(action, account: account, signer: model.signer)
        prepared = transaction

        if model.isHardware {
            progress = .signing
        }

        let signed = try await service.sign(transaction, account: account)

        progress = .sending

        switch try await service.submit(transaction, signed: signed, account: account, role: role) {
        case .confirmed:
            break
        case let .expired(hash):
            outcome = .expired(hash: hash)
        case let .submitted(hash):
            outcome = .submitted(hash: hash)
        }
    }

    /// Keeps checking while the outcome is open, so the sheet follows a late confirmation.
    func followOutcome() async {
        while outcome?.isUnresolved == true, !Task.isCancelled {
            try? await Task.sleep(for: .seconds(10))

            guard !Task.isCancelled else {
                return
            }

            await checkOutcome()
        }
    }

    func checkOutcome() async {
        guard let hash = outcome?.hash else {
            return
        }

        try? await service.checkAgain(model.account)

        // A resolved submission leaves the record; the tab shows what came of it.
        guard !(await service.isPending(hash, account: model.account)) else {
            return
        }

        dismiss()
    }
} // swiftlint:disable:this file_length
