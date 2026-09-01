//
//  TransferView.swift
//  Reefr Wallet
//
//  Created by Andrey Yurkevich on 22.02.26.
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import BigInt
import SwiftData
import SwiftUI
import WalletKit

// MARK: - TransferView

struct TransferView {
    private let account: Account

    @State private var decimalAmountText = "0"
    @State private var error: String?
    @State private var isAddressBookPresented = false
    @State private var isErrorAlertPresented = false
    @State private var isNextButtonEnabled = false
    @State private var isProgressPresented = false
    @State private var progress: Progress = .preparing
    @State private var receiverText = ""
    @State private var selectedBalance: Balance

    @State private var ethereumBaseFee: String = "0"
    @State private var ethereumMaxFee: String = "0"
    @State private var ethereumMaxPriorityFee: String = "0"

    @State private var suiGasBudget: String = "0"
    @State private var suiGasPrice: String = "0"

    @State private var nativeFeeReserve: BigUInt?
    @State private var feeEstimationTask: Task<Void, Never>?

    @Environment(\.dismiss) private var dismiss

    @Query var accountBalances: [BalanceModel]

    init(balance: Balance) {
        self.account = balance.account

        guard let accountId = account.id else {
            preconditionFailure()
        }

        let predicate = #Predicate<BalanceModel> { item in
           item.account.id == accountId
        }

        _accountBalances = Query(filter: predicate)
        _selectedBalance = .init(initialValue: balance)
    }
}

extension TransferView {
    enum Progress {
        case preparing
        case signing
        case sending

        var systemImage: String {
            switch self {
            case .preparing:
                "progress.indicator"
            case .signing:
                "lock.square.dashed"
            case .sending:
                "progress.indicator"
            }
        }

        var message: String {
            switch self {
            case .preparing:
                "Preparing transaction..."
            case .signing:
                "Follow instructions on your Trezor"
            case .sending:
                "Sending transaction..."
            }
        }
    }
}

// MARK: - View

extension TransferView: View {
    var body: some View {
        VStack(alignment: .leading) {
            Text("Send")
                .style(.largeHeader)
                .padding(.bottom)

            Form {
                accountSection
                tokenSection
                amountSection
                receiverSection
                    .padding(.bottom)
                feesSection
            }
            .padding(.bottom)

            buttons
        }
        .padding()
        .frame(maxWidth: .infinity)
        .sheet(isPresented: $isAddressBookPresented) {
            let blockchain = selectedBalance.account.blockchain

            let selectedAddress = Binding<String?> { nil } set: { address in
                if let address {
                    receiverText = address
                }
            }

            AddressBookView(blockchain: blockchain, selectedAddress: selectedAddress)
        }
        .sheet(isPresented: $isProgressPresented) {
            let image = Image(systemName: progress.systemImage)
                .resizable()
                .scaledToFit()
                .style(foreground: .secondary)
                .frame(width: 64, height: 64)
                .padding(.bottom)

            VStack {
                if case .sending = progress {
                    image.symbolEffect(.rotate.byLayer, options: .repeat(.continuous))
                } else {
                    image.symbolEffect(.breathe)
                }

                Text(progress.message)
                    .style(.large, foreground: .primary)
            }
            .padding(20)
        }
        .alert("Transaction Failed", isPresented: $isErrorAlertPresented) {
            Button("OK") {
                isErrorAlertPresented = false
            }
        } message: {
            if let error {
                Text(error)
            } else {
                Text("Unknown error")
            }
        }
        .onChange(of: receiverText) {
            validateInput()
        }
        .onChange(of: decimalAmountText) {
            validateInput()
        }
        .onChange(of: selectedBalance) {
            validateInput()
        }
        .onChange(of: ethereumMaxPriorityFee) {
            refreshNextButtonState()
        }
        .onChange(of: ethereumMaxFee) {
            refreshNextButtonState()
        }
        .onChange(of: suiGasBudget) {
            refreshNextButtonState()
        }
        .onChange(of: suiGasPrice) {
            refreshNextButtonState()
        }
    }
}

// MARK: - Subviews

private extension TransferView {
    var accountSection: some View {
        Section {
            LabeledContent {
                HStack {
                    Text(account.address)
                        .style(.medium, foreground: .secondary)
                }
                .frame(height: 28)
            } label: {
                Text("From")
                    .style(.small, foreground: .secondary)
            }
        }
    }

    var amountSection: some View {
        Section {
            LabeledContent {
                HStack {
                    TextField("", text: $decimalAmountText)
                        .style(.medium, foreground: .primary)

                    Button {
                        decimalAmountText = maxSendableAmount
                    } label: {
                        Image(systemName: "gauge.with.dots.needle.100percent")
                    }
                    .frame(width: 48)
                    .help("Maximum Amount")
                }
                .frame(height: 28)
            } label: {
                Text("Amount")
                    .style(.small, foreground: .secondary)
            }
        }
    }

    var buttons: some View {
        HStack {
            Button("Estimate Fees", action: onEstimateFees)
            Spacer()
            Button("Cancel", action: onCancel)
            Button("Next", action: onNext)
                .disabled(!isNextButtonEnabled)
        }
    }

    var receiverSection: some View {
        Section {
            LabeledContent {
                HStack {
                    TextField("", text: $receiverText)
                        .frame(maxWidth: .infinity)

                    Button {
                        onOpenAddressBook()
                    } label: {
                        Image(systemName: "book")
                    }
                    .frame(width: 48)
                    .help("Fill from Address Book")
                }
                .frame(height: 28)
            } label: {
                Text("Receiver")
                    .style(.small, foreground: .secondary)
            }
        }
    }

    var tokenSection: some View {
        Section {
            HStack(spacing: 2) {
                Picker(selection: $selectedBalance) {
                    ForEach(accountBalances, id: \.self) { balance in
                        Text(balance.token.name)
                            .style(.medium)
                    }
                } label: {
                    Text("Token")
                        .style(.small, foreground: .secondary)
                }

                Spacer()

                Text("BalanceModel:")
                    .style(.medium, foreground: .secondary)

                Text(verbatim: String(describing: selectedBalance.decimalAmount))
                    .style(.medium, foreground: .secondary)
                    .fixedSize()

                Text(selectedBalance.token.symbol)
                    .style(.medium, foreground: .secondary)
            }
            .frame(height: 28)
        }
    }
}

// MARK: - Fees

private extension TransferView {
    @ViewBuilder
    var feesSection: some View {
        Section {
            switch account.blockchain {
            case .evm:
                evmFeesForm
            case .sui:
                suiFeesForm
            default:
                EmptyView()
            }
        }
    }

    @ViewBuilder
    var evmFeesForm: some View {
        LabeledContent {
            TextField("", text: $ethereumBaseFee)
                .frame(height: 28)
                .disabled(true)
        } label: {
            Text("Base fee")
                .style(.small, foreground: .secondary)
        }

        LabeledContent {
            TextField("", text: $ethereumMaxPriorityFee)
                .frame(height: 28)
        } label: {
            Text("Max priority fee")
                .style(.small, foreground: .secondary)
        }

        LabeledContent {
            TextField("", text: $ethereumMaxFee)
                .frame(height: 28)
        } label: {
            Text("Max fee per gas")
                .style(.small, foreground: .secondary)
        }
    }

    @ViewBuilder
    var suiFeesForm: some View {
        LabeledContent {
            TextField("", text: $suiGasPrice)
        } label: {
            Text("Gas price")
                .style(.small, foreground: .secondary)
        }

        LabeledContent {
            TextField("", text: $suiGasBudget)
        } label: {
            Text("Gas limit")
                .style(.small, foreground: .secondary)
        }
    }
}

// MARK: - Callbacks

private extension TransferView {
    func onCancel() {
        dismiss()
    }

    func onEstimateFees() {
        feeEstimationTask?.cancel()
        feeEstimationTask = Task {
            let snapshot = (recipient: receiverText, amount: decimalAmountText, balance: selectedBalance)
            do {
                let fees = try await fetchFees()
                guard receiverText == snapshot.recipient,
                      decimalAmountText == snapshot.amount,
                      selectedBalance == snapshot.balance else { return }
                applyFees(fees)
                refreshNextButtonState()
            } catch {
                printError(error)
                isNextButtonEnabled = false
            }
        }
    }

    func onNext() {
        Task { @MainActor in
            do {
                isProgressPresented = true
                try await sendTransaction()
                isProgressPresented = false
                dismiss()
            } catch {
                isProgressPresented = false
                self.error = error.localizedDescription
                isErrorAlertPresented = true
            }
        }
    }

    func onOpenAddressBook() {
        // TODO: Address boook
    }
}

// MARK: - Logic

private extension TransferView {
    func fetchFees() async throws -> Fees {
        let transactionService = DI.injectOrFail(TransactionService.self)
        return try await transactionService.estimateFees(
            token: selectedBalance.token,
            decimalAmount: decimalAmountText,
            recipient: receiverText,
            account: account
        )
    }

    var maxSendableAmount: String {
        guard selectedBalance.token.isNativeToken, let reserve = nativeFeeReserve else {
            return "\(selectedBalance.decimalAmount)"
        }
        var divisor = Decimal(1)
        for _ in 0..<selectedBalance.token.decimalsCount { divisor *= 10 }
        let feeDecimal = (Decimal(string: reserve.description) ?? 0) / divisor
        let maxAmount = max(selectedBalance.decimalAmount - feeDecimal, 0)
        return "\(maxAmount)"
    }

    func applyFees(_ fees: Fees) {
        ethereumBaseFee = fees.ethereumBaseFee ?? ""
        ethereumMaxPriorityFee = fees.ethereumMaxPriorityFee ?? ""
        ethereumMaxFee = fees.ethereumMaxFee ?? ""
        suiGasBudget = fees.suiGasBudget ?? ""
        suiGasPrice = fees.suiGasPrice ?? ""
        nativeFeeReserve = fees.nativeFeeReserve.flatMap { BigUInt($0) }
    }

    func sendTransaction() async throws {
        let account = selectedBalance.account
        let databaseService = DI.injectOrFail(DatabaseService.self)

        let keyStore = try await databaseService.fetchKeyStore(id: selectedBalance.account.keyStoreId)
        if let keyStore, keyStore.isHardware {
            progress = .signing
        }

        let fees = Fees(
            ethereumBaseFee: ethereumBaseFee,
            ethereumMaxPriorityFee: ethereumMaxPriorityFee,
            ethereumMaxFee: ethereumMaxFee,
            suiGasBudget: suiGasBudget,
            suiGasPrice: suiGasPrice
        )

        let transactionService = DI.injectOrFail(TransactionService.self)

        let txData = try await transactionService.makeTransaction(
            token: selectedBalance.token,
            decimalAmount: decimalAmountText,
            recipient: receiverText,
            account: account,
            fees: fees
        )

        let txSignature = try await transactionService.signTransaction(txData, account: account)

        progress = .sending
        let receipt = try await transactionService.sendTransaction(txData, txSignature, account: account)
        printDebug(receipt)
    }

    func validateAddress() -> Bool {
        do {
            switch selectedBalance.account.blockchain {
            case .evm:
                _ = try EthereumAddress(string: receiverText)
            case .sui:
                _ = try SuiAddress(string: receiverText)
            default:
                return false
            }

            return true
        } catch {
            return false
        }
    }

    func validateAmount() -> Bool {
        guard
            let amount = Decimal(string: decimalAmountText),
            amount > 0,
            selectedBalance.decimalAmount >= amount
        else {
            return false
        }

        // Reject amounts that don't map exactly to a positive base-unit integer.
        // e.g. 0.0000001 USDC (6 decimals) scales to 0.1 base units → invalid.
        var multiplier = Decimal(1)
        let decimals = selectedBalance.token.decimalsCount
        for _ in 0..<decimals { multiplier *= 10 }
        let scaled = NSDecimalNumber(decimal: amount * multiplier)
        let handler = NSDecimalNumberHandler(
            roundingMode: .down, scale: 0,
            raiseOnExactness: false, raiseOnOverflow: false,
            raiseOnUnderflow: false, raiseOnDivideByZero: false
        )
        return scaled == scaled.rounding(accordingToBehavior: handler)
    }

    func validateFees() -> Bool {
        switch account.blockchain {
        case .evm:
            return BigUInt(ethereumMaxPriorityFee) != nil && BigUInt(ethereumMaxFee) != nil
        case .sui:
            return UInt64(suiGasBudget) != nil && UInt64(suiGasPrice) != nil
        default:
            return true
        }
    }

    /// Re-evaluates the Next button's enabled state after a manual edit to a
    /// fee field, without re-triggering fee estimation.
    func refreshNextButtonState() {
        isNextButtonEnabled = validateAddress() && validateAmount() && validateFees()
    }

    func validateInput() {
        feeEstimationTask?.cancel()
        feeEstimationTask = nil
        nativeFeeReserve = nil

        guard validateAddress(), validateAmount() else {
            isNextButtonEnabled = false
            return
        }

        feeEstimationTask = Task {
            // Debounce: absorb rapid keystrokes before hitting the network.
            do {
                try await Task.sleep(for: .seconds(1))
            } catch {
                return  // cancelled during the delay
            }

            // Snapshot the input that triggered this estimation so we can
            // discard the result if the user changed it while we were waiting.
            let snapshot = (recipient: receiverText, amount: decimalAmountText, balance: selectedBalance)
            do {
                let fees = try await fetchFees()
                guard receiverText == snapshot.recipient,
                      decimalAmountText == snapshot.amount,
                      selectedBalance == snapshot.balance else {
                    return
                }

                applyFees(fees)
                refreshNextButtonState()
            } catch {
                isNextButtonEnabled = false
            }
        }
    }
}

// MARK: - Preview

/* #Preview {
    let keyStore = try! KeyStoreModel.mockLocal() // swiftlint:disable:this force_try
    let account = keyStore.accounts!.first!
    let balance = account.balances.first!

    TransferView(balance: balance)
} */
