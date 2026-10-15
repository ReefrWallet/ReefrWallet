import SwiftUI
import WalletKit

enum TransactionRow: View {
    case aptos(TransactionRowModel)
    case bitcoin(TransactionRowModel)
    case cardano(TransactionRowModel)
    case evm(TransactionRowModel)
    case solana(TransactionRowModel)
    case sui(TransactionRowModel)
    case tron(TransactionRowModel)

    var body: some View {
        switch self {
        case let .aptos(model):
            AptosTransactionRow(model: model)
        case let .bitcoin(model):
            BitcoinTransactionRow(model: model)
        case let .cardano(model):
            CardanoTransactionRow(model: model)
        case let .evm(model):
            EVMTransactionRow(model: model)
        case let .solana(model):
            SolanaTransactionRow(model: model)
        case let .sui(model):
            SuiTransactionRow(model: model)
        case let .tron(model):
            TronTransactionRow(model: model)
        }
    }
}

extension TransactionRow {
    init(model: TransactionRowModel, blockchain: Blockchain) {
        switch blockchain {
        case .aptos:
            self = .aptos(model)
        case .bitcoin:
            self = .bitcoin(model)
        case .cardano:
            self = .cardano(model)
        case .evm:
            self = .evm(model)
        case .solana:
            self = .solana(model)
        case .sui:
            self = .sui(model)
        case .tron:
            self = .tron(model)
        }
    }
}
