import Foundation
import WalletKit

protocol TransactionRowPresenter: Sendable {
    func makeRowModel(_ transaction: WalletTransaction, account: Account) -> TransactionRowModel
    func supports(_ blockchain: Blockchain) -> Bool
}

enum TransactionRowPresenters {
    static func presenter(for blockchain: Blockchain) -> any TransactionRowPresenter {
        switch blockchain {
        case .bitcoin:
            BitcoinTransactionRowPresenter()
        case .cardano:
            CardanoTransactionRowPresenter()
        case .evm:
            EVMTransactionRowPresenter()
        case .solana:
            SolanaTransactionRowPresenter()
        case .sui:
            SuiTransactionRowPresenter()
        case .tron:
            TronTransactionRowPresenter()
        }
    }
}

struct BitcoinTransactionRowPresenter: TransactionRowPresenter {
    func makeRowModel(_ transaction: WalletTransaction, account: Account) -> TransactionRowModel {
        TransactionRowModel(transaction: transaction, account: account, direction: .ownedAddresses)
    }

    func supports(_ blockchain: Blockchain) -> Bool {
        if case .bitcoin = blockchain {
            true
        } else {
            false
        }
    }
}

struct CardanoTransactionRowPresenter: TransactionRowPresenter {
    func makeRowModel(_ transaction: WalletTransaction, account: Account) -> TransactionRowModel {
        TransactionRowModel(transaction: transaction, account: account, direction: .ownedAddresses)
    }

    func supports(_ blockchain: Blockchain) -> Bool {
        if case .cardano = blockchain {
            true
        } else {
            false
        }
    }
}

struct EVMTransactionRowPresenter: TransactionRowPresenter {
    func makeRowModel(_ transaction: WalletTransaction, account: Account) -> TransactionRowModel {
        TransactionRowModel(transaction: transaction, account: account, direction: .addresses)
    }

    func supports(_ blockchain: Blockchain) -> Bool {
        if case .evm = blockchain {
            true
        } else {
            false
        }
    }
}

struct SolanaTransactionRowPresenter: TransactionRowPresenter {
    func makeRowModel(_ transaction: WalletTransaction, account: Account) -> TransactionRowModel {
        TransactionRowModel(transaction: transaction, account: account, direction: .signedAmounts)
    }

    func supports(_ blockchain: Blockchain) -> Bool {
        if case .solana = blockchain {
            true
        } else {
            false
        }
    }
}

struct SuiTransactionRowPresenter: TransactionRowPresenter {
    func makeRowModel(_ transaction: WalletTransaction, account: Account) -> TransactionRowModel {
        TransactionRowModel(transaction: transaction, account: account, direction: .signedAmounts)
    }

    func supports(_ blockchain: Blockchain) -> Bool {
        if case .sui = blockchain {
            true
        } else {
            false
        }
    }
}

struct TronTransactionRowPresenter: TransactionRowPresenter {
    func makeRowModel(_ transaction: WalletTransaction, account: Account) -> TransactionRowModel {
        TransactionRowModel(transaction: transaction, account: account, direction: .addresses)
    }

    func supports(_ blockchain: Blockchain) -> Bool {
        if case .tron = blockchain {
            true
        } else {
            false
        }
    }
}

private extension TransactionRowModel {
    enum Direction {
        case addresses
        case ownedAddresses
        case signedAmounts
    }

    init(transaction: WalletTransaction, account: Account, direction: Direction) {
        let effects = transaction.effects.map {
            TransactionRowEffect(effect: $0, account: account, direction: direction)
        }
        let primaryEffect = effects.first
        let sender: String?
        let recipient: String?

        switch direction {
        case .signedAmounts:
            // Sui (and Solana) can spread one transaction's balance changes
            // across several effects with different counterparties — e.g. a
            // transfer leg plus a self-contained gas leg — so the first
            // effect isn't necessarily the real counterparty. Per-effect
            // `to`/`from` stay authoritative; there's no single top-level
            // counterparty to fall back to.
            sender = transaction.sender
            recipient = transaction.recipient
        case .addresses, .ownedAddresses:
            sender = transaction.sender ?? primaryEffect?.sender
            recipient = transaction.recipient ?? primaryEffect?.recipient
        }

        self.init(
            blockHeight: transaction.blockHeight,
            effects: effects,
            id: transaction.stableId,
            identifier: transaction.identifier,
            kind: Self.kind(
                effects: effects,
                recipient: recipient,
                sender: sender,
                accountAddress: account.address
            ),
            primaryEffect: primaryEffect,
            recipient: recipient,
            sender: sender,
            status: transaction.status,
            timestamp: transaction.timestamp
        )
    }

    static func kind(
        effects: [TransactionRowEffect],
        recipient: String?,
        sender: String?,
        accountAddress: String
    ) -> TransactionRowKind {
        guard !effects.isEmpty else {
            return .contractCall
        }

        if effects.contains(where: { $0.kind == BlockchainTransactionEffect.Kind.tokenApproval.rawValue }) {
            return .approval
        }

        // Sui (and Solana) transactions routinely split a single transfer into
        // several same-asset legs — e.g. the transfer itself plus a gas-payment
        // or coin-merge leg. Only genuinely different assets make this
        // `.multiAsset`; same-asset legs net into one signed amount below.
        guard Set(effects.map(\.assetIdentifier)).count == 1 else {
            return .multiAsset
        }

        // `sender`/`recipient` above fall back to the *first* effect, which
        // for Sui can be a self-contained gas leg rather than the actual
        // transfer — checking every effect here catches a same-asset,
        // multi-effect transaction that genuinely reaches another address,
        // even when that first effect alone looks like a self-transfer.
        let touchesOtherAddress = effects.contains { effect in
            let senderIsOther = effect.sender
                .map { $0.caseInsensitiveCompare(accountAddress) != .orderedSame } ?? false
            let recipientIsOther = effect.recipient
                .map { $0.caseInsensitiveCompare(accountAddress) != .orderedSame } ?? false
            return senderIsOther || recipientIsOther
        }

        if !touchesOtherAddress,
           sender?.caseInsensitiveCompare(accountAddress) == .orderedSame,
           recipient?.caseInsensitiveCompare(accountAddress) == .orderedSame {
            return .selfTransfer
        }

        guard let netAmount = effects.reduce(Decimal?.some(0), { total, effect in
            guard let total, let amount = effect.amount else {
                return nil
            }

            return total + amount
        }) else {
            return .unknown
        }

        if netAmount < 0 {
            return .sent
        }

        if netAmount > 0 {
            return .received
        }

        return .unknown
    }
}

private extension TransactionRowEffect {
    init(
        effect: WalletTransactionEffect,
        account: Account,
        direction: TransactionRowModel.Direction
    ) {
        let token = effect.balance?.token
        let decimals = token?.decimalsCount ?? account.blockchain.nativeToken.decimals
        let rawAmount = effect.amount.flatMap { Decimal(string: $0) }
        let unsignedAmount = rawAmount.map {
            $0 * Decimal(sign: .plus, exponent: -Int(decimals), significand: 1)
        }

        amount = Self.signedAmount(
            unsignedAmount,
            effect: effect,
            accountAddress: account.address,
            direction: direction
        )
        assetIdentifier = effect.assetIdentifier
        id = effect.stableId
        imageURL = token?.imageURL
        kind = effect.kind.rawValue
        recipient = effect.recipient
        sender = effect.sender
        symbol = token?.symbol ?? effect.assetIdentifier ?? account.blockchain.nativeToken.symbol
    }

    static func signedAmount(
        _ amount: Decimal?,
        effect: WalletTransactionEffect,
        accountAddress: String,
        direction: TransactionRowModel.Direction
    ) -> Decimal? {
        guard let amount else {
            return nil
        }

        switch direction {
        case .signedAmounts:
            return amount
        case .addresses, .ownedAddresses:
            let isSender = effect.sender?.caseInsensitiveCompare(accountAddress) == .orderedSame
            let isRecipient = effect.recipient?.caseInsensitiveCompare(accountAddress) == .orderedSame

            switch (isSender, isRecipient) {
            case (true, false):
                return -amount
            case (false, true):
                return amount
            default:
                return amount
            }
        }
    }
}
