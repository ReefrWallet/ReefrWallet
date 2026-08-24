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

    @State private var amountText = "0"
    @State private var error: String?
    @State private var isAddressBookPresented = false
    @State private var isErrorAlertPresented = false
    @State private var isNextButtonEnabled = false
    @State private var isProgressPresented = false
    @State private var progress: Progress = .preparing
    @State private var receiverText = ""
    @State private var selectedBalance: Balance

    @State private var ethereumBaseFee: String = "0"
    @State private var ethereumPriorityFee: String = "0"
    @State private var ethereumMaxFee: String = "0"
    @State private var suiGasBudget: String = "0"
    @State private var suiGasPrice: String = "0"

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
        .onChange(of: amountText) {
            validateInput()
        }
        .onChange(of: selectedBalance) {
            validateInput()
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
                    TextField("", text: $amountText)
                        .style(.medium, foreground: .primary)

                    Button {
                        amountText = "\(selectedBalance.decimalAmount)"
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
        } label: {
            Text("Base fee")
                .style(.small, foreground: .secondary)
        }

        LabeledContent {
            TextField("", text: $ethereumPriorityFee)
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
        Task {
            do {
                try await estimateFees()
                isNextButtonEnabled = true
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
    func estimateFees() async throws {
        /* let transactionService = DI.injectOrFail(TransactionService.self)

        let fees: Fees

        switch selectedBalance.account.blockchain.kind {
        case .evm:
            let tx = try await transactionService.makeTransaction(
                token: selectedBalance.token,
                decimalAmount: amountText,
                recipient: receiverText,
                account: account,
            )
            fees = try await transactionService.estimateFees(tx, account: account)
        case .sui:
            fees = try await transactionService.estimateFees(nil, account: account)
        }

        ethereumBaseFee = fees.ethereumBaseFee ?? ""
        ethereumPriorityFee = fees.ethereumPriorityFee ?? ""
        ethereumMaxFee = fees.ethereumMaxFee ?? ""
        suiGasBudget = fees.suiGasBudget ?? ""
        suiGasPrice = fees.suiGasPrice ?? "" */
    }

    func sendTransaction() async throws {
        /* let account = selectedBalance.account

        if let keyStore = selectedBalance.account.keyStore, keyStore.isHardware {
            progress = .signing
        }

        let fees = Fees(
            ethereumBaseFee: ethereumBaseFee,
            ethereumPriorityFee: ethereumPriorityFee,
            ethereumMaxFee: ethereumMaxFee,
            suiGasBudget: suiGasBudget,
            suiGasPrice: suiGasPrice
        )

        let transactionService = DI.injectOrFail(TransactionService.self)

        let txData = try await transactionService.makeTransaction(
            token: selectedBalance.token,
            decimalAmount: amountText,
            recipient: receiverText,
            account: account,
            fees: fees
        )

        let txSignature = try await transactionService.signTransaction(txData, account: account)

        progress = .sending
        let receipt = try await transactionService.sendTransaction(txData, txSignature, account: account)
        printDebug(receipt) */
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
            let amount = Decimal(string: amountText),
            amount >= selectedBalance.decimalAmount
        else {
            return false
        }

        return true
    }

    func validateInput() {
        guard validateAddress(), validateAmount() else {
            isNextButtonEnabled = false
            return
        }

        Task {
            do {
                try await estimateFees()
                isNextButtonEnabled = true
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
