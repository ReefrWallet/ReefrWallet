import SwiftUI

struct AptosTransactionRow: View {
    let model: TransactionRowModel

    var body: some View {
        TransactionRowLayout(model: model, subtitle: model.blockHeight.map { "Version \($0)" } ?? "Pending") {
            TransactionEffectsDetail(effects: model.effects)
        }
    }
}

struct BitcoinTransactionRow: View {
    let model: TransactionRowModel

    var body: some View {
        TransactionRowLayout(model: model, subtitle: model.blockHeight.map { "Block #\($0)" } ?? "In mempool") {
            TransactionEffectsDetail(effects: model.effects)
        }
    }
}

struct CardanoTransactionRow: View {
    let model: TransactionRowModel

    var body: some View {
        TransactionRowLayout(model: model, subtitle: model.blockHeight.map { "Block #\($0)" } ?? "Pending") {
            TransactionEffectsDetail(effects: model.effects)
        }
    }
}

struct EVMTransactionRow: View {
    let model: TransactionRowModel

    var body: some View {
        TransactionRowLayout(model: model, subtitle: model.blockHeight.map { "Block #\($0)" } ?? "Pending") {
            TransactionEffectsDetail(effects: model.effects)
        }
    }
}

struct SolanaTransactionRow: View {
    let model: TransactionRowModel

    var body: some View {
        TransactionRowLayout(model: model, subtitle: model.blockHeight.map { "Slot \($0)" } ?? "Pending") {
            TransactionEffectsDetail(effects: model.effects)
        }
    }
}

struct SuiTransactionRow: View {
    let model: TransactionRowModel

    var body: some View {
        TransactionRowLayout(model: model, subtitle: model.blockHeight.map { "Checkpoint \($0)" } ?? "Pending") {
            TransactionEffectsDetail(effects: model.effects)
        }
    }
}

struct TronTransactionRow: View {
    let model: TransactionRowModel

    var body: some View {
        TransactionRowLayout(model: model, subtitle: model.blockHeight.map { "Block #\($0)" } ?? "Pending") {
            TransactionEffectsDetail(effects: model.effects)
        }
    }
}
