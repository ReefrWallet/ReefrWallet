import Foundation
import WalletKit

/// Per-chain presentation: how effects are signed, how blocks are named and which table columns apply.
protocol TransactionRowPresenter: Sendable {
    var schema: TransactionTableSchema { get }

    func makeRowModel(_ transaction: WalletTransaction, account: Account) -> TransactionRowModel
}

/// Column titles for the iPad/Mac transactions table; a `nil` title hides that column.
struct TransactionTableSchema: Hashable, Sendable {
    let amountTitle: String
    let blockTitle: String
    let feeTitle: String
    let fromTitle: String?
    let hashTitle: String
    let methodTitle: String
    let showsDirection: Bool
    let toTitle: String?
}

enum TransactionRowPresenters {
    static func presenter(for blockchain: Blockchain) -> any TransactionRowPresenter {
        switch blockchain {
        case .aptos:
            AptosTransactionRowPresenter()
        case .bitcoin:
            BitcoinTransactionRowPresenter()
        case .cardano:
            CardanoTransactionRowPresenter()
        case let .evm(chain):
            EVMTransactionRowPresenter(feeSymbol: chain.nativeToken.symbol)
        case .solana:
            SolanaTransactionRowPresenter()
        case .sui:
            SuiTransactionRowPresenter()
        case .tron:
            TronTransactionRowPresenter()
        }
    }
}

/// Aptos effects are the account's own signed net amounts per asset.
struct AptosTransactionRowPresenter: TransactionRowPresenter {
    let schema = TransactionTableSchema(
        amountTitle: "Amount",
        blockTitle: "Version",
        feeTitle: "Gas (APT)",
        fromTitle: "Sender",
        hashTitle: "Hash",
        methodTitle: "Function",
        showsDirection: false,
        toTitle: nil
    )

    func makeRowModel(_ transaction: WalletTransaction, account: Account) -> TransactionRowModel {
        TransactionRowModel(
            transaction: transaction,
            account: account,
            direction: .signedAmounts,
            blockLabel: transaction.blockHeight.map { "Version \($0)" } ?? "Pending"
        )
    }
}

/// Bitcoin effects are net UTXO deltas; there's no single sender/recipient to tabulate.
struct BitcoinTransactionRowPresenter: TransactionRowPresenter {
    let schema = TransactionTableSchema(
        amountTitle: "Balance Change",
        blockTitle: "Block",
        feeTitle: "Fee (BTC)",
        fromTitle: nil,
        hashTitle: "Transaction ID",
        methodTitle: "Type",
        showsDirection: false,
        toTitle: nil
    )

    func makeRowModel(_ transaction: WalletTransaction, account: Account) -> TransactionRowModel {
        TransactionRowModel(
            transaction: transaction,
            account: account,
            direction: .ownedAddresses,
            blockLabel: transaction.blockHeight.map { "Block #\($0)" } ?? "In mempool"
        )
    }
}

struct CardanoTransactionRowPresenter: TransactionRowPresenter {
    let schema = TransactionTableSchema(
        amountTitle: "Balance Change",
        blockTitle: "Block",
        feeTitle: "Fee (ADA)",
        fromTitle: nil,
        hashTitle: "Hash",
        methodTitle: "Type",
        showsDirection: false,
        toTitle: nil
    )

    func makeRowModel(_ transaction: WalletTransaction, account: Account) -> TransactionRowModel {
        TransactionRowModel(
            transaction: transaction,
            account: account,
            direction: .ownedAddresses,
            blockLabel: transaction.blockHeight.map { "Block #\($0)" } ?? "Pending"
        )
    }
}

struct EVMTransactionRowPresenter: TransactionRowPresenter {
    let schema: TransactionTableSchema

    init(feeSymbol: String = "ETH") {
        schema = TransactionTableSchema(
            amountTitle: "Amount",
            blockTitle: "Block",
            feeTitle: "Fee (\(feeSymbol))",
            fromTitle: "From",
            hashTitle: "Hash",
            methodTitle: "Method",
            showsDirection: true,
            toTitle: "To"
        )
    }

    func makeRowModel(_ transaction: WalletTransaction, account: Account) -> TransactionRowModel {
        TransactionRowModel(
            transaction: transaction,
            account: account,
            direction: .addresses,
            blockLabel: transaction.blockHeight.map { "Block #\($0)" } ?? "Pending"
        )
    }
}

/// Solana effects are signed balance deltas; the target program stands in for a recipient.
struct SolanaTransactionRowPresenter: TransactionRowPresenter {
    let schema = TransactionTableSchema(
        amountTitle: "Value",
        blockTitle: "Slot",
        feeTitle: "Fee (SOL)",
        fromTitle: "Signer",
        hashTitle: "Signature",
        methodTitle: "Action",
        showsDirection: false,
        toTitle: "Program"
    )

    func makeRowModel(_ transaction: WalletTransaction, account: Account) -> TransactionRowModel {
        TransactionRowModel(
            transaction: transaction,
            account: account,
            direction: .signedAmounts,
            blockLabel: transaction.blockHeight.map { "Slot \($0)" } ?? "Pending"
        )
    }
}

struct SuiTransactionRowPresenter: TransactionRowPresenter {
    let schema = TransactionTableSchema(
        amountTitle: "Amount",
        blockTitle: "Checkpoint",
        feeTitle: "Gas (SUI)",
        fromTitle: nil,
        hashTitle: "Digest",
        methodTitle: "Type",
        showsDirection: false,
        toTitle: "Activity With"
    )

    func makeRowModel(_ transaction: WalletTransaction, account: Account) -> TransactionRowModel {
        TransactionRowModel(
            transaction: transaction,
            account: account,
            direction: .signedAmounts,
            blockLabel: transaction.blockHeight.map { "Checkpoint \($0)" } ?? "Pending"
        )
    }
}

struct TronTransactionRowPresenter: TransactionRowPresenter {
    let schema = TransactionTableSchema(
        amountTitle: "Amount",
        blockTitle: "Block",
        feeTitle: "Fee (TRX)",
        fromTitle: "From",
        hashTitle: "Hash",
        methodTitle: "Type",
        showsDirection: true,
        toTitle: "To"
    )

    func makeRowModel(_ transaction: WalletTransaction, account: Account) -> TransactionRowModel {
        TransactionRowModel(
            transaction: transaction,
            account: account,
            direction: .addresses,
            blockLabel: transaction.blockHeight.map { "Block #\($0)" } ?? "Pending"
        )
    }
}

private extension TransactionRowModel {
    enum Direction {
        case addresses
        case ownedAddresses
        case signedAmounts
    }

    init(transaction: WalletTransaction, account: Account, direction: Direction, blockLabel: String) {
        let effects = transaction.effects.map {
            TransactionRowEffect(effect: $0, account: account, direction: direction)
        }

        let primaryEffect = effects.first
        let (sender, recipient) = Self.parties(
            transaction: transaction,
            primaryEffect: primaryEffect,
            direction: direction
        )

        let kind = Self.kind(
            effects: effects,
            recipient: recipient,
            sender: sender,
            accountAddress: account.address
        )

        let nativeToken = account.blockchain.nativeToken
        let isOwnRecipient = recipient?.caseInsensitiveCompare(account.address) == .orderedSame
        let otherParty = Self.otherParty(
            effects: effects,
            recipient: recipient,
            sender: sender,
            accountAddress: account.address
        )

        self.init(
            blockHeight: transaction.blockHeight,
            blockLabel: blockLabel,
            effects: effects,
            fee: transaction.fee.flatMap { Decimal(string: $0) }.map { $0.scaled(by: nativeToken.decimals) },
            feeSymbol: nativeToken.symbol,
            fromLabel: Self.label(sender, account: account),
            id: transaction.stableId,
            identifier: transaction.identifier,
            kind: kind,
            method: transaction.method,
            primaryEffect: primaryEffect,
            recipient: recipient,
            sender: sender,
            status: transaction.status,
            subtitle: Self.subtitle(
                kind: kind,
                counterpartyName: transaction.counterpartyName,
                otherParty: otherParty,
                identifier: transaction.identifier
            ),
            timestamp: transaction.timestamp,
            toLabel: isOwnRecipient
                ? Self.label(recipient, account: account)
                : transaction.counterpartyName ?? Self.label(recipient ?? otherParty, account: account)
        )
    }

    static func parties(
        transaction: WalletTransaction,
        primaryEffect: TransactionRowEffect?,
        direction: Direction
    ) -> (sender: String?, recipient: String?) {
        switch direction {
        case .signedAmounts:
            // Sui (and Solana) can spread one transaction's balance changes
            // across several effects with different counterparties — e.g. a
            // transfer leg plus a self-contained gas leg — so the first
            // effect isn't necessarily the real counterparty. Per-effect
            // `to`/`from` stay authoritative; there's no single top-level
            // counterparty to fall back to.
            (transaction.sender, transaction.recipient)
        case .addresses, .ownedAddresses:
            (transaction.sender ?? primaryEffect?.sender, transaction.recipient ?? primaryEffect?.recipient)
        }
    }

    /// Short address, or the account's name when it's the account itself.
    static func label(_ address: String?, account: Account) -> String? {
        guard let address else {
            return nil
        }

        return address.caseInsensitiveCompare(account.address) == .orderedSame ? account.name : address.shortened()
    }

    /// The address on the other side of the transaction, if any.
    static func otherParty(
        effects: [TransactionRowEffect],
        recipient: String?,
        sender: String?,
        accountAddress: String
    ) -> String? {
        let isOther = { (address: String?) in
            address.map { $0.caseInsensitiveCompare(accountAddress) != .orderedSame } ?? false
        }

        if isOther(sender) {
            return sender
        }

        if isOther(recipient) {
            return recipient
        }

        return effects.lazy.flatMap { [$0.sender, $0.recipient] }.first(where: isOther) ?? nil
    }

    static func subtitle(
        kind: TransactionRowKind,
        counterpartyName: String?,
        otherParty: String?,
        identifier: String
    ) -> String {
        if let counterpartyName {
            return counterpartyName
        }

        guard let otherParty else {
            return identifier.shortened()
        }

        return kind == .received ? "From \(otherParty.shortened())" : "To \(otherParty.shortened())"
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
        guard Set(effects.map(\.assetKey)).count == 1 else {
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

        let unsignedAmount = rawAmount.map { $0.scaled(by: decimals) }

        amount = Self.signedAmount(
            unsignedAmount,
            effect: effect,
            accountAddress: account.address,
            direction: direction
        )

        assetClass = Self.assetClass(effect, blockchain: account.blockchain)
        assetIdentifier = effect.assetIdentifier
        id = effect.stableId
        imageURL = token?.imageURL
        kind = effect.kind.rawValue
        recipient = effect.recipient
        sender = effect.sender
        symbol = token?.symbol ?? effect.assetIdentifier ?? account.blockchain.nativeToken.symbol
    }

    /// Only ERC-721 transfers are recognizable: their log indexes the token ID as a 4th topic.
    static func assetClass(_ effect: WalletTransactionEffect, blockchain: Blockchain) -> TransactionAssetClass {
        guard case .evm = blockchain,
              effect.kind == .tokenTransfer,
              let log: EVMLogTopics = try? effect.rawPayload?.decoded(),
              log.topics.count == 4 else {
            return .token
        }

        return .nft(tokenId: log.topics[3])
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

/// `rawPayload` of an EVM log-derived effect.
private struct EVMLogTopics: Decodable {
    let topics: [String]
}

private extension Decimal {
    /// Smallest-unit integer → whole units.
    func scaled(by decimals: UInt8) -> Decimal {
        self * Decimal(sign: .plus, exponent: -Int(decimals), significand: 1)
    }
}
