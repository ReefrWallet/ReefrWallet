import Foundation
import WalletKit

protocol TransactionRowPresenter: Sendable {
    func makeRowModel(_ transaction: WalletTransaction, account: Account) -> TransactionRowModel
    func supports(_ blockchain: WKBlockchain) -> Bool
}

enum TransactionRowPresenters {
    static func presenter(for blockchain: WKBlockchain) -> any TransactionRowPresenter {
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

    func supports(_ blockchain: WKBlockchain) -> Bool {
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

    func supports(_ blockchain: WKBlockchain) -> Bool {
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

    func supports(_ blockchain: WKBlockchain) -> Bool {
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

    func supports(_ blockchain: WKBlockchain) -> Bool {
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

    func supports(_ blockchain: WKBlockchain) -> Bool {
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

    func supports(_ blockchain: WKBlockchain) -> Bool {
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
        let sender = transaction.sender ?? primaryEffect?.sender
        let recipient = transaction.recipient ?? primaryEffect?.recipient

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

        if effects.count > 1 {
            return .multiAsset
        }

        if sender?.caseInsensitiveCompare(accountAddress) == .orderedSame,
           recipient?.caseInsensitiveCompare(accountAddress) == .orderedSame {
            return .selfTransfer
        }

        guard let amount = effects[0].amount else {
            return .unknown
        }

        if amount < 0 {
            return .sent
        }

        if amount > 0 {
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
