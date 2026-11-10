//
//  SolanaStakingSheet.swift
//  Reefr Wallet
//
//  Created by Andrey Yurkevich on 06.11.26.
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import SwiftUI
import WalletKit

// MARK: - SolanaStakingSheetOutcome

/// What the sheet shows once it has stopped asking for input (the Penpot `Outcome` usecase).
enum SolanaStakingSheetOutcome: Equatable {
    case expired(signature: String)
    case failed(signature: String)
    /// It expired waiting for the signature, so nothing was sent.
    case signAgain
    case submitted(signature: String)
    case unknown(signature: String)

    var signature: String? {
        switch self {
        case let .expired(signature), let .failed(signature), let .submitted(signature), let .unknown(signature):
            signature
        case .signAgain:
            nil
        }
    }

    var isUnresolved: Bool {
        switch self {
        case .submitted, .unknown: true
        default: false
        }
    }
}

// MARK: - SolanaStakingSheet

/// The send/sign sheet of every Solana staking action (ADR-054, built on ``TransactionSheet``):
/// parameters and read-only fees, then Estimate Fees, Cancel and Next, which signs, records and
/// broadcasts, or the outcome of doing that.
@MainActor
struct SolanaStakingSheet {
    let kind: SolanaStakingSheetKind
    let model: SolanaStakingModel

    @State private var amountText = ""
    @State private var balance: UInt64 = 0
    @State private var error: String?
    @State private var isErrorAlertPresented = false
    @State private var isPickerPresented = false
    @State private var minimum: UInt64 = 0
    @State private var outcome: SolanaStakingSheetOutcome?
    @State private var prepareError: String?
    @State private var prepared: SolanaPreparedStaking?
    @State private var prepareTask: Task<Void, Never>?
    /// The send in flight, shown in the prompt popup; `nil` when idle.
    @State private var progress: TransactionProgress?
    @State private var rent: UInt64 = 0
    /// Stake accounts picked, by address.
    @State private var selection: Set<String> = []
    @State private var selectionLimit = Int.max
    @State private var validator: SolanaValidator?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    private let service = DI.injectOrFail(SolanaStakingService.self)

    init(kind: SolanaStakingSheetKind, model: SolanaStakingModel) {
        self.kind = kind
        self.model = model
    }
}

// MARK: - View

extension SolanaStakingSheet: View {
    var body: some View {
        TransactionSheet(
            title: title,
            confirmTitle: confirmTitle,
            isConfirmEnabled: isConfirmEnabled,
            isEstimateFeesEnabled: isEstimateEnabled,
            isProcessing: progress != nil,
            cancelTitle: cancelTitle,
            isCancelHidden: isSubmitted,
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
                    isSolanaStaking: true,
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
        .sheet(isPresented: $isPickerPresented) {
            SolanaValidatorPicker(validators: model.validators, selection: $validator)
        }
        .task {
            await loadInitialValues()
        }
        .task(id: outcome?.signature) {
            await followOutcome()
        }
        .onChange(of: action, initial: true) {
            schedulePreparation()
        }
        .onChange(of: selection) { _, new in
            onSelectionChange(new)
        }
    }
}

// MARK: - Parameters

private extension SolanaStakingSheet {
    @ViewBuilder
    var parameters: some View {
        switch kind {
        case .stake:
            ParameterSection(String(localized: .solanaStakingGroupStake), footer: stakeNote) {
                FromRow(account: model.account)
                ParameterRow(
                    String(localized: .tronStakingRowAvailable),
                    value: SolanaStakingFormat.sol(balance),
                    subtitle: model.usdText(lamports: balance)
                )

                validatorRow
                ParameterRow(String(localized: .solanaStakingRowRent), value: SolanaStakingFormat.sol(rent))
                amountField
            }

        case .unstake:
            ParameterSection(String(localized: .solanaStakingGroupUnstake), footer: unstakeNote) {
                FromRow(account: model.account)
                accountList
                unstakeTotals
            }

        case .withdraw:
            ParameterSection(String(localized: .solanaStakingGroupWithdraw), footer: withdrawNote) {
                FromRow(account: model.account)
                accountList
                ParameterRow(String(localized: .tronStakingWithdraw), value: SolanaStakingFormat.sol(selectedLamports))
                ParameterRow(
                    String(localized: .tronStakingRowValue),
                    value: model.usdText(lamports: selectedLamports) ?? ""
                )
            }
        }
    }

    var validatorRow: some View {
        ParameterRow(String(localized: .solanaStakingRowValidator)) {
            Button {
                isPickerPresented = true

                Task {
                    await model.refreshValidators()
                }
            } label: {
                HStack {
                    Text(verbatim: validator?.name ?? validator?.voteAddress.shortened(prefix: 6, suffix: 4)
                        ?? String(localized: .solanaStakingSelectValidator))

                    Spacer()

                    Image(systemName: "chevron.up.chevron.down")
                        .imageScale(.small)
                }
            }
            .accessibilityIdentifier("staking-validator-button")
        }
    }

    var amountField: some View {
        ParameterRow(String(localized: .commonAmount)) {
            HStack {
                TextField("", text: $amountText)
                    .accessibilityIdentifier("staking-amount-field")

                Button {
                    amountText = "\(SolanaStakingFormat.decimalSol(maxAmount))"
                } label: {
                    Image("max16")
                }
                .buttonStyle(.borderless)
                .help(.transferParametersMaximumAmount)
            }
        }
    }

    @ViewBuilder
    var accountList: some View {
        #if os(macOS)
        VStack(alignment: .leading, spacing: 12) {
            ForEach(listedPositions, id: \.account.address) { position in
                accountRow(position)
            }
        }
        .padding(10)
        .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.secondary.opacity(0.3)))
        #else
        ForEach(listedPositions, id: \.account.address) { position in
            accountRow(position)
        }
        #endif
    }

    func accountRow(_ position: SolanaStakePosition) -> some View {
        let address = position.account.address
        let isEligible = eligible(position)
        let isSelected = selection.contains(address)
        let isCapped = !isSelected && selection.count >= selectionLimit
        let amount = kind == .withdraw ? position.account.lamports : position.account.delegation?.stake ?? 0

        return Toggle(isOn: Binding(
            get: { isSelected },
            set: { isOn in
                if isOn {
                    selection.insert(address)
                } else {
                    selection.remove(address)
                }
            }
        )) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: model.name(of: position.account.delegation?.voter))
                        .style(isIOS ? .large : .medium, foreground: isEligible ? .primary : .secondary)

                    Text(verbatim: reason(position) ?? model.statusText(position))
                        .style(.small, foreground: .secondary)
                }

                Spacer()

                Text(verbatim: SolanaStakingFormat.sol(amount))
                    .style(.medium, foreground: isEligible ? .primary : .secondary)
            }
        }
        .disabled(!isEligible || isCapped)
        .accessibilityIdentifier("stake-account-\(address)")
    }

    @ViewBuilder
    var unstakeTotals: some View {
        if let single = selectedSingle {
            ParameterRow(
                String(localized: .solanaStakingRowInAccount),
                value: SolanaStakingFormat.sol(single.account.delegation?.stake ?? 0),
                subtitle: model.usdText(lamports: single.account.delegation?.stake ?? 0)
            )

            if single.account.withdrawer == model.account.address {
                amountField

                if let remaining = partialRemaining {
                    ParameterRow(
                        String(localized: .solanaStakingRowRemaining),
                        value: SolanaStakingFormat.sol(remaining)
                    )

                    ParameterRow(
                        String(localized: .solanaStakingRowNewAccountRent),
                        value: SolanaStakingFormat.sol(rent)
                    )
                }
            } else {
                ParameterRow(
                    String(localized: .commonAmount),
                    value: String(localized: .solanaStakingFullAccountOnly)
                )
            }
        } else {
            ParameterRow(
                String(localized: .solanaStakingRowUnstaking),
                value: SolanaStakingFormat.sol(selectedLamports)
            )

            ParameterRow(
                String(localized: .tronStakingRowValue),
                value: model.usdText(lamports: selectedLamports) ?? ""
            )
        }
    }

    func outcomeSection(_ outcome: SolanaStakingSheetOutcome) -> some View {
        ParameterSection(String(localized: .solanaStakingGroupTransaction), footer: outcomeNote(outcome)) {
            FromRow(account: model.account)

            if let action = action ?? prepared?.action {
                ParameterRow(String(localized: .solanaStakingRowAction), value: SolanaStakingModel.actionText(action))
            }

            ParameterRow(String(localized: .solanaStakingRowStatus), value: outcomeStatus(outcome))

            if let signature = outcome.signature {
                ParameterRow(
                    String(localized: .solanaStakingRowSignature),
                    value: signature.shortened(prefix: 4, suffix: 4)
                )
            }
        }
    }
}

// MARK: - Logic

private extension SolanaStakingSheet {
    var title: String {
        switch kind {
        case .stake: String(localized: .tronStakingStake)
        case .unstake: String(localized: .tronStakingUnstake)
        case .withdraw: String(localized: .tronStakingWithdraw)
        }
    }

    var confirmTitle: String {
        switch outcome {
        case nil: String(localized: .commonNext)
        case .expired, .failed: String(localized: .solanaStakingTryAgain)
        case .signAgain: String(localized: .solanaStakingSignAgain)
        case .submitted: String(localized: .solanaStakingClose)
        case .unknown: String(localized: .solanaStakingCheckAgain)
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
        case nil, .failed, .submitted, .unknown: onEstimateFees
        case .expired, .signAgain: nil
        }
    }

    var estimatedFees: Fees? {
        prepared.map {
            Fees(
                nativeFeeReserve: String($0.estimate.fee),
                solanaComputeUnitLimit: $0.estimate.computeUnitLimit.map(String.init),
                solanaPriorityFee: String($0.estimate.computeUnitPrice)
            )
        }
    }

    var isSubmitted: Bool {
        if case .submitted = outcome {
            true
        } else {
            false
        }
    }

    var owner: String {
        model.account.address
    }

    /// The rows the selection is made from: this action's own candidates, then the ones it
    /// can't touch, with the reason. Sorted so the list doesn't move.
    var listedPositions: [SolanaStakePosition] {
        let relevant = model.positions.filter { position in
            switch kind {
            case .stake, .unstake:
                position.status == .active || position.status == .activating
            case .withdraw:
                position.status == .inactive || position.status == .undelegated
            }
        }

        return relevant.sorted { eligible($0) && !eligible($1) }
    }

    func eligible(_ position: SolanaStakePosition) -> Bool {
        switch kind {
        case .stake:
            false
        case .unstake:
            position.canUnstake(owner: owner)
        case .withdraw:
            model.details.map { position.canWithdraw(owner: owner, at: $0.clock) } ?? false
        }
    }

    /// Why this wallet can't act on `position`, if it can't.
    func reason(_ position: SolanaStakePosition) -> String? {
        guard !eligible(position) else {
            return nil
        }

        if kind == .unstake {
            return String(localized: .solanaStakingReasonStakerElsewhere)
        }

        guard let clock = model.details?.clock, position.account.isLocked(at: clock) else {
            return String(localized: .solanaStakingReasonWithdrawerElsewhere)
        }

        return String(localized: .solanaStakingReasonLocked(lockupEnd(position.account, clock: clock)))
    }

    /// `Mar 2027`, or `epoch 1200` when the epoch is what's still ahead.
    func lockupEnd(_ account: SolanaStakeAccount, clock: SolanaClock) -> String {
        guard account.lockup.unixTimestamp > clock.unixTimestamp else {
            return String(localized: .solanaStakingEpochNumber(Int(clamping: account.lockup.epoch)))
        }

        let date = Date(timeIntervalSince1970: TimeInterval(account.lockup.unixTimestamp))
        return date.formatted(.dateTime.month(.abbreviated).year())
    }

    var selectedPositions: [SolanaStakePosition] {
        model.positions.filter { selection.contains($0.account.address) }
    }

    var selectedLamports: UInt64 {
        selectedPositions
            .map { kind == .withdraw ? $0.account.lamports : $0.account.delegation?.stake ?? 0 }
            .saturatingSum
    }

    /// The account whose amount can be edited: exactly one selected.
    var selectedSingle: SolanaStakePosition? {
        selectedPositions.count == 1 ? selectedPositions.first : nil
    }

    var maxAmount: UInt64 {
        switch kind {
        case .stake:
            SolanaStakingService.maxStake(balance: balance, rent: rent)
        case .unstake:
            selectedSingle?.account.delegation?.stake ?? 0
        case .withdraw:
            0
        }
    }

    var typedLamports: UInt64? {
        let blockchain = model.account.blockchain
        let token = Token(address: nil, blockchain: blockchain, tokenInfo: blockchain.nativeToken)

        return (try? token.smallestUnitAmount(from: amountText)).flatMap { UInt64(exactly: $0) }
    }

    /// What's left in the account after a partial unstake; `nil` for a full one.
    var partialRemaining: UInt64? {
        guard
            let stake = selectedSingle?.account.delegation?.stake,
            let typedLamports,
            typedLamports < stake
        else {
            return nil
        }

        return stake - typedLamports
    }

    var limitNote: String? {
        let eligibleCount = listedPositions.filter(eligible).count

        guard eligibleCount > selectionLimit, selection.count >= selectionLimit else {
            return nil
        }

        return String(localized: .solanaStakingNoteSelectionLimit(selection.count, eligibleCount))
    }

    var stakeNote: String {
        let minimumNote = String(localized: .solanaStakingNoteStake(SolanaStakingFormat.sol(minimum)))
        return [minimumNote, model.nextEpochText().map { "\($0)." }].compactMap { $0 }.joined(separator: " ")
    }

    var unstakeNote: String {
        if let limitNote {
            return "\(limitNote) \(String(localized: .solanaStakingNoteCooldown))"
        }

        guard let single = selectedSingle else {
            return unstakeCooldownNote
        }

        guard single.account.withdrawer == owner else {
            return String(localized: .solanaStakingNoteFullOnly)
        }

        guard partialRemaining != nil, let typedLamports else {
            return unstakeCooldownNote
        }

        if let clock = model.details?.clock, single.account.isLocked(at: clock) {
            return String(localized: .solanaStakingNotePartialLocked(
                SolanaStakingFormat.sol(typedLamports),
                lockupEnd(single.account, clock: clock)
            ))
        }

        return String(localized: .solanaStakingNotePartial(SolanaStakingFormat.sol(typedLamports)))
    }

    var unstakeCooldownNote: String {
        let note = String(localized: .solanaStakingNoteUnstake)
        return [note, model.nextEpochText().map { "\($0)." }].compactMap { $0 }.joined(separator: " ")
    }

    var withdrawNote: String {
        limitNote ?? String(localized: .solanaStakingNoteWithdraw)
    }

    func outcomeStatus(_ outcome: SolanaStakingSheetOutcome) -> String {
        switch outcome {
        case .expired: String(localized: .solanaStakingOutcomeExpired)
        case .failed: String(localized: .solanaStakingOutcomeFailed)
        case .signAgain: String(localized: .solanaStakingOutcomeSignAgain)
        case .submitted: String(localized: .solanaStakingOutcomeSubmitted)
        case .unknown: String(localized: .solanaStakingOutcomeUnknown)
        }
    }

    func outcomeNote(_ outcome: SolanaStakingSheetOutcome) -> String {
        switch outcome {
        case .expired: String(localized: .solanaStakingOutcomeExpiredNote)
        case .failed: String(localized: .solanaStakingOutcomeFailedNote)
        case .signAgain: String(localized: .solanaStakingOutcomeSignAgainNote)
        case .submitted: String(localized: .solanaStakingOutcomeSubmittedNote)
        case .unknown: String(localized: .solanaStakingOutcomeUnknownNote)
        }
    }

    /// The action the inputs describe; `nil` until they are complete.
    var action: SolanaStakingAction? {
        switch kind {
        case .stake:
            guard let validator, let typedLamports else {
                return nil
            }

            return .stake(lamports: typedLamports, voter: validator.voteAddress)

        case .unstake:
            return SolanaStakingModel.unstakeAction(selected: selectedPositions, owner: owner, amount: typedLamports)

        case .withdraw:
            guard !selection.isEmpty else {
                return nil
            }

            return .withdraw(selectedPositions.map {
                SolanaStakingAction.Withdrawal(address: $0.account.address, lamports: $0.account.lamports)
            })
        }
    }

    func loadInitialValues() async {
        let account = model.account

        async let loadedBalance = try? service.availableBalance(for: account)
        async let loadedMinimum = try? service.minimumDelegation(for: account)
        async let loadedRent = try? service.rent(for: account)

        balance = await loadedBalance ?? 0
        minimum = await loadedMinimum ?? 0
        rent = await loadedRent ?? 0

        await model.refreshValidators()

        // The ones already earning are worth nothing to preselect; the best is a sensible start.
        if kind == .stake, validator == nil {
            validator = model.validators.first { !$0.isDelinquent }
        }

        selectionLimit = computeSelectionLimit()

        if kind == .unstake, let first = listedPositions.first(where: eligible) {
            selection = [first.account.address]
        } else if kind == .withdraw {
            selection = Set(listedPositions.filter(eligible).prefix(selectionLimit).map(\.account.address))
        }
    }

    func computeSelectionLimit() -> Int {
        guard
            kind != .stake,
            let address = try? SolanaAddress(string: owner)
        else {
            return .max
        }

        let addresses = listedPositions.filter(eligible).compactMap { try? SolanaAddress(string: $0.account.address) }

        guard
            let limit = try? SolanaStakingTransactions.selectionLimit(
                owner: address,
                addresses: addresses,
                isWithdrawal: kind == .withdraw
            ),
            limit < addresses.count
        else {
            return .max
        }

        return limit
    }

    /// A new single account starts from its full amount; more than one can only be whole.
    func onSelectionChange(_ new: Set<String>) {
        guard kind == .unstake else {
            return
        }

        if let single = selectedSingle?.account.delegation?.stake {
            amountText = "\(SolanaStakingFormat.decimalSol(single))"
        } else {
            amountText = ""
        }
    }

    func onCancel() {
        dismiss()
    }

    /// While the outcome is open, Estimate Fees is the explorer link.
    func onEstimateFees() {
        if let signature = outcome?.signature {
            if let url = model.explorerURL(signature: signature) {
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
            guard let action = prepared?.action else {
                return
            }

            send(action)
        case .signAgain:
            if let action = prepared?.action {
                outcome = nil
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
            let transaction = try await service.prepare(action, account: model.account)

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

    func send(_ action: SolanaStakingAction) {
        Task { @MainActor in
            do {
                try await $progress.track {
                    try await run(action)
                }

                if outcome == nil {
                    dismiss()
                }
            } catch SolanaStakingError.expiredBeforeSending {
                outcome = .signAgain
            } catch {
                self.error = error.localizedDescription
                isErrorAlertPresented = true
            }
        }
    }

    /// Rebuilds with a new blockhash just before signing, then sends what was signed.
    func run(_ action: SolanaStakingAction) async throws {
        let account = model.account
        let transaction = try await service.prepare(action, account: account)
        prepared = transaction

        if model.isHardware {
            progress = .signing
        }

        let signature = try await service.sign(transaction, account: account)

        progress = .sending

        switch try await service.submit(transaction, signature: signature, account: account) {
        case .confirmed:
            break
        case .failed:
            outcome = .failed(signature: SolanaRPCClient.signatureString(signature))
        case let .submitted(identifier):
            outcome = .submitted(signature: identifier)
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
        guard let signature = outcome?.signature else {
            return
        }

        try? await service.checkAgain(model.account)

        switch await service.latestUpdate(for: signature) {
        case .confirmed:
            dismiss()
        case .expired:
            outcome = .expired(signature: signature)
        case .failed:
            outcome = .failed(signature: signature)
        case let .unresolved(pending):
            outcome = pending.isPastValidity ? .unknown(signature: signature) : .submitted(signature: signature)
        case nil:
            break
        }
    }
} // swiftlint:disable:this file_length
