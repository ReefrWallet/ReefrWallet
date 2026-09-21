//
//  TransferParametersView.swift
//  Reefr Wallet
//
//  Created by Andrey Yurkevich on 15.09.26.
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import BigInt
import SwiftData
import SwiftUI
import WalletKit

// MARK: - TransferParameters

/// A fully validated transfer request. Non-nil ⇒ the from/to/token/amount part
/// of the form is ready to proceed.
struct TransferParameters: Equatable {
    let balance: Balance
    let decimalAmount: String
    let recipient: String
}

// MARK: - TransferParametersView

struct TransferParametersView {
    private let account: Account

    let nativeFeeReserve: BigUInt?

    @Binding var parameters: TransferParameters?

    @State private var decimalAmountText = "0"
    @State private var isAddressBookPresented = false
    @State private var receiverText = ""
    @State private var selectedBalanceId: PersistentIdentifier?

    @Query var accountBalances: [BalanceModel]

    init(balance: Balance, nativeFeeReserve: BigUInt?, parameters: Binding<TransferParameters?>) {
        account = balance.account
        self.nativeFeeReserve = nativeFeeReserve
        _parameters = parameters

        guard let accountId = account.id else {
            preconditionFailure()
        }

        let predicate = #Predicate<BalanceModel> { item in
           item.account.id == accountId
        }

        _accountBalances = Query(filter: predicate)
        _selectedBalanceId = .init(initialValue: balance.id)
    }
}

// MARK: - View

extension TransferParametersView: View {
    var body: some View {
        Group {
            accountSection
            tokenSection
            amountSection
            receiverSection
                .padding(.bottom)
                .sheet(isPresented: $isAddressBookPresented) {
                    let selectedAddress = Binding<String?> { nil } set: { address in
                        if let address {
                            receiverText = address
                        }
                    }

                    AddressBookView(blockchain: account.blockchain, selectedAddress: selectedAddress)
                }
                .onChange(of: validatedParameters, initial: true) { _, newValue in
                    parameters = newValue
                }
        }
    }
}

// MARK: - Subviews

private extension TransferParametersView {
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
                Picker(selection: $selectedBalanceId) {
                    ForEach(accountBalances, id: \.self) { balance in
                        Text(balance.token.symbol)
                            .style(.medium)
                            .tag(balance.id as PersistentIdentifier?)
                    }
                } label: {
                    Text("Token")
                        .style(.small, foreground: .secondary)
                }

                Spacer()

                if let selectedBalance {
                    Text("Balance:")
                        .style(.medium, foreground: .secondary)

                    Text(verbatim: String(describing: selectedBalance.decimalAmount))
                        .style(.medium, foreground: .secondary)
                        .fixedSize()

                    Text(selectedBalance.token.symbol)
                        .style(.medium, foreground: .secondary)
                }
            }
            .frame(height: 28)
        }
    }
}

// MARK: - Callbacks

private extension TransferParametersView {
    func onOpenAddressBook() {
        // TODO: Address boook
    }
}

// MARK: - Logic

private extension TransferParametersView {
    var selectedBalance: Balance? {
        accountBalances
            .first { $0.id == selectedBalanceId }
            .flatMap { try? Balance(model: $0) }
    }

    /// Non-nil only when the recipient address and amount both validate for the
    /// selected token — the signal that the transfer can proceed.
    var validatedParameters: TransferParameters? {
        guard let selectedBalance, validateAddress(), validateAmount(selectedBalance) else {
            return nil
        }

        return TransferParameters(
            balance: selectedBalance,
            decimalAmount: decimalAmountText,
            recipient: receiverText
        )
    }

    var maxSendableAmount: String {
        guard let selectedBalance else {
            return "0"
        }

        guard selectedBalance.token.isNativeToken, let reserve = nativeFeeReserve else {
            return "\(selectedBalance.decimalAmount)"
        }
        var divisor = Decimal(1)
        for _ in 0..<selectedBalance.token.decimalsCount { divisor *= 10 }
        let feeDecimal = (Decimal(string: reserve.description) ?? 0) / divisor
        let maxAmount = max(selectedBalance.decimalAmount - feeDecimal, 0)
        return "\(maxAmount)"
    }

    func validateAddress() -> Bool {
        do {
            switch account.blockchain {
            case .evm:
                _ = try EthereumAddress(string: receiverText)
            case .sui:
                _ = try SuiAddress(string: receiverText)
            case .solana:
                _ = try SolanaAddress(string: receiverText)
            default:
                return false
            }

            return true
        } catch {
            return false
        }
    }

    func validateAmount(_ balance: Balance) -> Bool {
        guard
            let amount = Decimal(string: decimalAmountText),
            amount > 0,
            balance.decimalAmount >= amount
        else {
            return false
        }

        // Reject amounts that don't map exactly to a positive base-unit integer.
        // e.g. 0.0000001 USDC (6 decimals) scales to 0.1 base units → invalid.
        var multiplier = Decimal(1)
        let decimals = balance.token.decimalsCount
        for _ in 0..<decimals { multiplier *= 10 }
        let scaled = NSDecimalNumber(decimal: amount * multiplier)
        let handler = NSDecimalNumberHandler(
            roundingMode: .down, scale: 0,
            raiseOnExactness: false, raiseOnOverflow: false,
            raiseOnUnderflow: false, raiseOnDivideByZero: false
        )

        return scaled == scaled.rounding(accordingToBehavior: handler)
    }
}
