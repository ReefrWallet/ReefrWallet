//
//  TransferParametersView.swift
//  Reefr Wallet
//
//  Created by Andrey Yurkevich on 15.09.26.
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import SwiftData
import SwiftUI
import WalletKit

// MARK: - TransferParameters

/// A fully validated transfer request. Non-nil ⇒ the from/to/token/amount part
/// of the form is ready to proceed.
struct TransferParameters: Equatable {
    let balance: Balance
    let cardanoRecipientLovelace: String?
    let decimalAmount: String
    let recipient: String
}

// MARK: - TransferParametersView

struct TransferParametersView {
    private let account: Account

    let nativeFeeReserve: BigUInt?

    @Binding var parameters: TransferParameters?
    /// The selected token, even while the rest of the form is invalid.
    @Binding var token: Token

    @State private var decimalAmountText = "0"
    @State private var cardanoRecipientLovelaceText = ""
    @State private var isAddressBookPresented = false
    @State private var receiverText = ""
    @State private var selectedBalanceId: PersistentIdentifier?

    @Query var accountBalances: [BalanceModel]

    init(
        balance: Balance,
        nativeFeeReserve: BigUInt?,
        parameters: Binding<TransferParameters?>,
        token: Binding<Token>
    ) {
        account = balance.account
        self.nativeFeeReserve = nativeFeeReserve
        _parameters = parameters
        _token = token

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
        ParameterSection("Transfer") {
            FromRow(account: account)
            tokenRow
            amountRow
            cardanoRecipientLovelaceRow
            receiverRow
        }
        .sheet(isPresented: $isAddressBookPresented) {
            let selectedAddress = Binding<String?> { nil } set: { address in
                if let address {
                    receiverText = address
                }
            }

            AddressBookView(blockchain: account.blockchain, selectedAddress: selectedAddress)
        }
        .onChange(of: selectedBalanceId) {
            onSelectBalance()
        }
        .onChange(of: validatedParameters, initial: true) { _, newValue in
            parameters = newValue
        }
    }
}

// MARK: - Subviews

private extension TransferParametersView {
    var amountRow: some View {
        ParameterRow("Amount") {
            HStack {
                TextField("", text: $decimalAmountText)
                    .accessibilityIdentifier("transfer-amount-field")

                Button {
                    decimalAmountText = maxSendableAmount
                } label: {
                    Image("max16")
                }
                .buttonStyle(.borderless)
                .help("Maximum Amount")
            }
        }
    }

    @ViewBuilder
    var cardanoRecipientLovelaceRow: some View {
        if isCardanoNativeAsset {
            ParameterRow("Recipient ADA (lovelace)") {
                TextField("", text: $cardanoRecipientLovelaceText)
            }
        }
    }

    var receiverRow: some View {
        ParameterRow("Receiver") {
            HStack {
                TextField("", text: $receiverText, prompt: Text(receiverPrompt))
                    .accessibilityIdentifier("transfer-receiver-field")

                Button {
                    onOpenAddressBook()
                } label: {
                    Image("addressBook16")
                }
                .buttonStyle(.borderless)
                .help("Fill from Address Book")
            }
        }
    }

    var tokenRow: some View {
        ParameterRow("Token") {
            VStack(alignment: .leading, spacing: 4) {
                Picker(selection: $selectedBalanceId) {
                    ForEach(accountBalances, id: \.self) { balance in
                        Text(balance.token.symbol)
                            .tag(balance.id as PersistentIdentifier?)
                    }
                } label: {
                    EmptyView()
                }
                .labelsHidden()

                if let selectedBalance {
                    Text(verbatim: "Balance: \(selectedBalance.decimalAmount) \(selectedBalance.token.symbol)")
                        .style(.small, foreground: .secondary)
                }
            }
        }
    }
}

// MARK: - Callbacks

private extension TransferParametersView {
    func onOpenAddressBook() {
        // TODO: Address boook
    }

    /// An amount for the previous token is meaningless for the new one.
    func onSelectBalance() {
        decimalAmountText = "0"

        if let selectedBalance {
            token = selectedBalance.token
        }
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
            cardanoRecipientLovelace: isCardanoNativeAsset ? cardanoRecipientLovelaceText : nil,
            decimalAmount: decimalAmountText,
            recipient: receiverText
        )
    }

    /// The receiver field's placeholder, e.g. "0x…" or "bc1…".
    var receiverPrompt: String {
        switch account.blockchain {
        case .aptos, .evm, .sui: "0x…"
        case .bitcoin: "bc1…"
        case .cardano: "addr1…"
        case .solana: "Address"
        case .tron: "T…"
        }
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

    var isCardanoNativeAsset: Bool {
        guard case .cardano = account.blockchain else {
            return false
        }

        return !(selectedBalance?.token.isNativeToken ?? true)
    }

    /// Exhaustive over `Blockchain` on purpose: a `default` that rejects
    /// everything silently disables the whole form for any chain missing a
    /// case here, so a newly supported chain must fail to compile instead.
    func validateAddress() -> Bool {
        do {
            switch account.blockchain {
            case .aptos:
                _ = try AptosAddress(string: receiverText)
            case let .bitcoin(network):
                _ = try BitcoinDescriptor(address: receiverText, network: network)
            case let .cardano(network):
                _ = try CardanoAddress(string: receiverText, network: network)
            case .evm:
                _ = try EthereumAddress(string: receiverText)
            case .solana:
                _ = try SolanaAddress(string: receiverText)
            case .sui:
                _ = try SuiAddress(string: receiverText)
            case .tron:
                _ = try TronAddress(string: receiverText)
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

        guard scaled == scaled.rounding(accordingToBehavior: handler) else {
            return false
        }

        guard !isCardanoNativeAsset else {
            return UInt64(cardanoRecipientLovelaceText) != nil
        }

        return true
    }
}
