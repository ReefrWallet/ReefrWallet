//
//  DappTransactionPreview+Fees.swift
//  Reefr Wallet
//
//  Created by Andrey Yurkevich on 21.10.26.
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import Foundation
import WalletKit

extension DappTransactionPreview {
    /// The fees the transaction already carries, for the read-only Fees section.
    /// Only Ethereum's are editable (ADR-042): the other chains' dapps keep the
    /// bytes they built, so a rewrite would not match the returned signature.
    var fees: Fees {
        switch self {
        case let .aptos(preview):
            let transaction = preview.transaction
            let (maxFee, overflow) = transaction.maxGasAmount.multipliedReportingOverflow(by: transaction.gasUnitPrice)
            return Fees(
                aptosGasUnitPrice: String(transaction.gasUnitPrice),
                aptosMaxGasAmount: String(transaction.maxGasAmount),
                nativeFeeReserve: overflow ? nil : String(maxFee)
            )

        case let .cardano(preview):
            return Fees(nativeFeeReserve: preview.transaction.fee)

        case let .ethereum(_, fees):
            return fees

        case let .solana(preview):
            let budget = SolanaComputeBudget(preview.transaction)
            let maxFee = budget.maxFee(signatureCount: preview.transaction.header.numRequiredSignatures)
            return Fees(
                nativeFeeReserve: String(maxFee),
                solanaComputeUnitLimit: budget.unitLimit.map(String.init),
                solanaPriorityFee: budget.unitPrice.map(String.init)
            )

        case let .sui(preview):
            return Fees(
                nativeFeeReserve: String(preview.summary.gasBudget),
                suiGasBudget: String(preview.summary.gasBudget),
                suiGasPrice: String(preview.summary.gasPrice)
            )

        case let .tron(preview):
            return Fees(
                nativeFeeReserve: preview.fee.map { String($0.burnedSun) },
                tronFeeLimit: preview.transaction.feeLimit.map(String.init)
            )
        }
    }
}

// MARK: - SolanaComputeBudget

/// The Compute Budget program's `SetComputeUnitLimit` (tag 2, u32 LE) and
/// `SetComputeUnitPrice` (tag 3, u64 LE µLamports) instructions.
struct SolanaComputeBudget: Equatable {
    /// Per-instruction default when no limit is set, and the transaction cap.
    static let defaultUnitsPerInstruction: UInt64 = 200_000
    static let lamportsPerSignature: UInt64 = 5_000
    static let maxUnits: UInt64 = 1_400_000

    /// Instructions other than Compute Budget ones, which consume no default budget.
    let instructionCount: Int
    let unitLimit: UInt32?
    let unitPrice: UInt64?

    init(instructionCount: Int, unitLimit: UInt32?, unitPrice: UInt64?) {
        self.instructionCount = instructionCount
        self.unitLimit = unitLimit
        self.unitPrice = unitPrice
    }

    init(_ transaction: SolanaWireTransaction) {
        var instructionCount = 0
        var unitLimit: UInt32?
        var unitPrice: UInt64?

        for instruction in transaction.instructions {
            let programIndex = Int(instruction.programIdIndex)
            guard
                programIndex < transaction.staticAccountKeys.count,
                transaction.staticAccountKeys[programIndex] == SolanaProgram.computeBudget
            else {
                instructionCount += 1
                continue
            }

            let data = instruction.data
            switch data.first {
            case 2 where data.count == 5:
                unitLimit = UInt32(littleEndianBytes: data.dropFirst())
            case 3 where data.count == 9:
                unitPrice = UInt64(littleEndianBytes: data.dropFirst())
            default:
                break
            }
        }

        self.init(instructionCount: instructionCount, unitLimit: unitLimit, unitPrice: unitPrice)
    }

    /// Units the priority fee is charged on: the requested limit, else the default.
    var units: UInt64 {
        if let unitLimit {
            return min(UInt64(unitLimit), Self.maxUnits)
        }

        return min(UInt64(instructionCount) * Self.defaultUnitsPerInstruction, Self.maxUnits)
    }

    /// Base signature fees plus the priority fee, rounded up, in lamports;
    /// `UInt64.max` if that overflows.
    func maxFee(signatureCount: UInt8) -> UInt64 {
        let microLamports = (unitPrice ?? 0).multipliedFullWidth(by: units)
        guard microLamports.high < 1_000_000 else {
            return .max
        }

        let (quotient, remainder) = UInt64(1_000_000).dividingFullWidth(microLamports)
        let priorityFee = remainder == 0 ? quotient : quotient + 1
        let (fee, overflow) = (UInt64(signatureCount) * Self.lamportsPerSignature).addingReportingOverflow(priorityFee)
        return overflow ? .max : fee
    }
}

private extension FixedWidthInteger {
    init(littleEndianBytes bytes: Data.SubSequence) {
        self = bytes.reversed().reduce(0) { $0 << 8 | Self($1) }
    }
}
