//
//  SuiStakingSheet.swift
//  Reefr Wallet
//
//  Created by Andrey Yurkevich on 08.11.26.
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import SwiftUI
import WalletKit

// MARK: - SuiStakingSheetOutcome

/// What the sheet shows once it has stopped asking for input (the Penpot `Outcome` usecase).
enum SuiStakingSheetOutcome: Equatable {
    /// Proven never to have run: it expired, or another transaction spent its inputs.
    case expired(digest: String)
    case failed(digest: String)
    case submitted(digest: String)
    case unknown(digest: String)

    var digest: String {
        switch self {
        case let .expired(digest), let .failed(digest), let .submitted(digest), let .unknown(digest): digest
        }
    }

    var isUnresolved: Bool {
        switch self {
        case .submitted, .unknown: true
        default: false
        }
    }
}

// MARK: - SuiStakingSheet

/// The send/sign sheet of every Sui staking action (ADR-060, built on ``TransactionSheet``):
/// parameters and read-only fees, then Estimate Fees, Cancel and Next, which signs, records and
/// broadcasts, or the outcome of doing that.
@MainActor
struct SuiStakingSheet {
    let kind: SuiStakingSheetKind
    let model: SuiStakingModel

    @State var amountText = ""
    @State var balance: UInt64 = 0
    @State var error: String?
    @State var isErrorAlertPresented = false
    @State var isPickerPresented = false
    @State var outcome: SuiStakingSheetOutcome?
    @State var prepareError: String?
    @State var prepared: SuiPreparedStaking?
    @State var prepareTask: Task<Void, Never>?
    /// The send in flight, shown in the prompt popup; `nil` when idle.
    @State var progress: TransactionProgress?
    /// The receipt to unstake, by object id.
    @State var selection: String?
    @State var validator: SuiValidator?

    @Environment(\.dismiss) var dismiss
    @Environment(\.openURL) var openURL

    let service = DI.injectOrFail(SuiStakingService.self)

    init(kind: SuiStakingSheetKind, model: SuiStakingModel) {
        self.kind = kind
        self.model = model
    }
}

// MARK: - View

extension SuiStakingSheet: View {
    var body: some View {
        TransactionSheet(
            title: kind == .stake ? String(localized: .tronStakingStake) : String(localized: .tronStakingUnstake),
            confirmTitle: confirmTitle,
            isConfirmEnabled: outcome != nil || prepared != nil,
            isEstimateFeesEnabled: outcome != nil || action != nil,
            isProcessing: progress != nil,
            cancelTitle: outcome == nil ? nil : String(localized: .solanaStakingClose),
            isCancelHidden: isSubmitted,
            estimateTitle: outcome == nil ? nil : String(localized: .solanaStakingViewInExplorer),
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
                    estimatedFees: prepared.map { Fees(nativeFeeReserve: String($0.netFee)) },
                    isEditable: false,
                    isSuiStaking: true,
                    warning: prepareError,
                    fees: .constant(nil)
                )
            }
        }
        .alert(.transferTransactionFailed, isPresented: $isErrorAlertPresented) {
            Button(.commonOk) {
                isErrorAlertPresented = false
            }
        } message: {
            Text(verbatim: error ?? String(localized: .transferUnknownError))
        }
        .sheet(isPresented: $isPickerPresented) {
            SuiValidatorPicker(validators: model.validators, selection: $validator)
        }
        .task {
            await loadInitialValues()
        }
        .task(id: outcome?.digest) {
            await followOutcome()
        }
        .onChange(of: action, initial: true) {
            schedulePreparation()
        }
        .onChange(of: selection) {
            onSelectionChange()
        }
    }
}

// MARK: - Parameters

private extension SuiStakingSheet {
    @ViewBuilder
    var parameters: some View {
        switch kind {
        case .stake:
            ParameterSection(String(localized: .suiStakingGroupStake), footer: stakeNote) {
                FromRow(account: model.account)
                ParameterRow(
                    String(localized: .tronStakingRowAvailable),
                    value: SuiStakingFormat.sui(balance),
                    subtitle: model.usdText(mist: balance)
                )

                validatorRow

                if let validator {
                    ParameterRow(
                        String(localized: .suiStakingRowValidator),
                        value: String(localized: .suiStakingCommission(SuiValidatorPicker.commissionText(validator)))
                    )
                }

                amountField(isEnabled: true)

                if let left = prepared?.leftForGas {
                    ParameterRow(String(localized: .suiStakingRowLeftForGas), value: SuiStakingFormat.sui(left))
                }
            }

        case .unstake:
            ParameterSection(String(localized: .suiStakingGroupUnstake), footer: unstakeNote) {
                FromRow(account: model.account)
                stakeList
                unstakeTotals
            }
        }
    }

    var validatorRow: some View {
        ParameterRow(String(localized: .suiStakingRowValidator)) {
            Button {
                isPickerPresented = true

                Task {
                    await model.refreshValidators()
                }
            } label: {
                HStack {
                    Text(verbatim: validator?.name ?? String(localized: .suiStakingSelectValidator))

                    Spacer()

                    Image(systemName: "chevron.up.chevron.down")
                        .imageScale(.small)
                }
            }
            .accessibilityIdentifier("staking-validator-button")
        }
    }

    func amountField(isEnabled: Bool) -> some View {
        ParameterRow(String(localized: .commonAmount)) {
            HStack {
                TextField("", text: $amountText)
                    .disabled(!isEnabled)
                    .accessibilityIdentifier("staking-amount-field")

                Button {
                    amountText = "\(SuiStakingFormat.decimalSui(maxAmount))"
                } label: {
                    Image("max16")
                }
                .buttonStyle(.borderless)
                .disabled(!isEnabled)
                .help(.transferParametersMaximumAmount)
            }
        }
    }

    @ViewBuilder
    var stakeList: some View {
        #if os(macOS)
        VStack(alignment: .leading, spacing: 12) {
            ForEach(model.positions, id: \.stake.objectId) { position in
                stakeRow(position)
            }
        }
        .padding(10)
        .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.secondary.opacity(0.3)))
        #else
        ForEach(model.positions, id: \.stake.objectId) { position in
            stakeRow(position)
        }
        #endif
    }

    func stakeRow(_ position: SuiStakePosition) -> some View {
        let id = position.stake.objectId

        return Toggle(isOn: Binding(
            get: { selection == id },
            set: { isOn in
                if isOn {
                    selection = id
                }
            }
        )) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: model.name(of: position))
                        .style(isPhone ? .large : .medium, foreground: .primary)

                    Text(verbatim: SuiStakingModel.statusText(position))
                        .style(.small, foreground: .secondary)
                }

                Spacer()

                Text(verbatim: SuiStakingFormat.sui(position.stake.principal))
                    .style(.medium, foreground: .primary)
            }
        }
        .accessibilityIdentifier("stake-\(id)")
    }

    @ViewBuilder
    var unstakeTotals: some View {
        if let position = selectedPosition {
            ParameterRow(
                String(localized: .suiStakingRowInStake),
                value: SuiStakingFormat.sui(position.stake.principal),
                subtitle: model.usdText(mist: position.stake.principal)
            )

            if SuiStakingModel.canSplit(position.stake) {
                amountField(isEnabled: true)

                if let remaining = partialRemaining {
                    ParameterRow(String(localized: .suiStakingRowRemaining), value: SuiStakingFormat.sui(remaining))
                }
            } else {
                ParameterRow(String(localized: .commonAmount), value: String(localized: .suiStakingFullStakeOnly))
            }

            if let payout = estimatedPayout {
                ParameterRow(
                    String(localized: .suiStakingEstimatedPayout),
                    value: SuiStakingFormat.sui(payout),
                    subtitle: model.usdText(mist: payout)
                )
            }
        }
    }

    func outcomeSection(_ outcome: SuiStakingSheetOutcome) -> some View {
        ParameterSection(String(localized: .suiStakingGroupTransaction), footer: outcomeNote(outcome)) {
            FromRow(account: model.account)

            if let action = action ?? prepared?.action {
                ParameterRow(String(localized: .suiStakingRowAction), value: SuiStakingModel.kindText(action.kind))
            }

            ParameterRow(String(localized: .suiStakingRowStatus), value: outcomeStatus(outcome))
            ParameterRow(String(localized: .suiStakingRowDigest), value: outcome.digest.shortened(prefix: 4, suffix: 4))
        }
    }
}

// MARK: - Logic

extension SuiStakingSheet {
    var confirmTitle: String {
        switch outcome {
        case nil: String(localized: .commonNext)
        case .expired, .failed: String(localized: .solanaStakingTryAgain)
        case .submitted: String(localized: .solanaStakingClose)
        case .unknown: String(localized: .solanaStakingCheckAgain)
        }
    }

    /// Estimate Fees before sending; afterwards the explorer link, unless nothing landed.
    var estimateAction: (() -> Void)? {
        switch outcome {
        case nil, .failed, .submitted, .unknown: onEstimateFees
        case .expired: nil
        }
    }

    var isSubmitted: Bool {
        if case .submitted = outcome {
            true
        } else {
            false
        }
    }

    var selectedPosition: SuiStakePosition? {
        model.positions.first { $0.stake.objectId == selection }
    }

    var maxAmount: UInt64 {
        switch kind {
        case .stake:
            SuiStakingService.maxStake(liquid: balance)
        case .unstake:
            selectedPosition?.stake.principal ?? 0
        }
    }

    var typedMist: UInt64? {
        let blockchain = model.account.blockchain
        let token = Token(address: nil, blockchain: blockchain, tokenInfo: blockchain.nativeToken)

        return (try? token.smallestUnitAmount(from: amountText)).flatMap { UInt64(exactly: $0) }
    }

    /// What's left staked after a partial unstake; `nil` for a full one.
    var partialRemaining: UInt64? {
        guard let principal = selectedPosition?.stake.principal, let typedMist, typedMist < principal else {
            return nil
        }

        return principal - typedMist
    }

    /// The principal paid out plus the part of the estimated rewards that goes with it.
    var estimatedPayout: UInt64? {
        selectedPosition.flatMap { SuiStakingModel.estimatedPayout($0, amount: typedMist) }
    }

    var stakeNote: String {
        let minimum = String(localized: .suiStakingNoteStake(SuiStakingFormat.sui(SuiStakingFramework.minimumStake)))
        var parts = [minimum, model.nextEpochText().map { "\($0)." }]

        if let left = prepared?.leftForGas, left < SuiStakingFunding.unstakeReserve {
            parts.append(String(localized: .suiStakingNoteGasLeft(SuiStakingFormat.sui(left))))
        } else {
            let reserve = SuiStakingFormat.sui(SuiStakingFunding.unstakeReserve)
            parts.append(String(localized: .suiStakingNoteKeepsReserve(reserve)))
        }

        return parts.compactMap { $0 }.joined(separator: " ")
    }

    var unstakeNote: String {
        guard let position = selectedPosition else {
            return String(localized: .suiStakingNoteUnstake)
        }

        if !SuiStakingModel.canSplit(position.stake) {
            return String(localized: .suiStakingNoteFullOnly(SuiStakingFormat.sui(SuiStakingFramework.minimumStake)))
        }

        if let remaining = partialRemaining, let typedMist {
            let amount = SuiStakingFormat.sui(typedMist)
            return String(localized: .suiStakingNotePartial(amount, SuiStakingFormat.sui(remaining)))
        }

        return position.status == .pending
            ? String(localized: .suiStakingNoteUnstakePending)
            : String(localized: .suiStakingNoteUnstake)
    }

    func outcomeStatus(_ outcome: SuiStakingSheetOutcome) -> String {
        switch outcome {
        case .expired: String(localized: .solanaStakingOutcomeExpired)
        case .failed: String(localized: .solanaStakingOutcomeFailed)
        case .submitted: String(localized: .solanaStakingOutcomeSubmitted)
        case .unknown: String(localized: .solanaStakingOutcomeUnknown)
        }
    }

    func outcomeNote(_ outcome: SuiStakingSheetOutcome) -> String {
        switch outcome {
        case .expired: String(localized: .solanaStakingOutcomeExpiredNote)
        case .failed: String(localized: .solanaStakingOutcomeFailedNote)
        case .submitted: String(localized: .solanaStakingOutcomeSubmittedNote)
        case .unknown: String(localized: .solanaStakingOutcomeUnknownNote)
        }
    }

    /// The action the inputs describe; `nil` until they are complete.
    var action: SuiStakingAction? {
        switch kind {
        case .stake:
            guard let validator, let typedMist, let address = try? SuiAddress(string: validator.address) else {
                return nil
            }

            return .stake(validator: address, amount: typedMist)

        case .unstake:
            return SuiStakingModel.unstakeAction(stake: selectedPosition?.stake, amount: typedMist)
        }
    }

    func loadInitialValues() async {
        balance = (try? await service.availableBalance(for: model.account)) ?? 0

        await model.refreshValidators()

        if kind == .stake, validator == nil {
            validator = model.validators.first
        }

        if kind == .unstake, selection == nil {
            selection = model.positions.first?.stake.objectId
        }
    }

    /// A newly chosen stake starts from its full amount.
    func onSelectionChange() {
        guard kind == .unstake else {
            return
        }

        amountText = selectedPosition.map { "\(SuiStakingFormat.decimalSui($0.stake.principal))" } ?? ""
    }

    func onCancel() {
        dismiss()
    }

    /// While the outcome is open, Estimate Fees is the explorer link.
    func onEstimateFees() {
        if let outcome {
            if let url = model.explorerURL(digest: outcome.digest) {
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
            if let action = prepared?.action {
                send(action)
            }

        case .expired, .failed:
            outcome = nil
            schedulePreparation()
        case .submitted:
            dismiss()
        case .unknown:
            Task {
                await checkOutcome()
            }
        }
    }
}
