// Test doubles for SuiDappProviderTests.swift's chain-query coverage —
// split into their own file purely to keep that file under its
// line-count limit.

import Foundation
import Testing
import WalletKit
@testable import ReefrWallet

/// Captures the last request it was asked to approve, then answers with
/// a preset result — for asserting on a transaction's preview (e.g. its
/// decoded `moveCalls`) in the same test that approves it.
final class RecordingApproving: DappApproving, @unchecked Sendable {
    let result: DappApprovalResult
    private(set) var lastRequest: DappApprovalRequest?

    init(result: DappApprovalResult) {
        self.result = result
    }

    func approve(_ request: DappApprovalRequest) async -> DappApprovalResult {
        lastRequest = request
        return result
    }
}

/// A fake ``SuiDappChainQuerying`` — lets tests exercise the new
/// `get*`/`simulateTransaction` lookup methods and the MoveCall
/// approval path offline, without a live Sui node.
final class FakeSuiDappChainQuerying: SuiDappChainQuerying, @unchecked Sendable {
    var coinsByType: [String: [SuiCoinObject]] = [:]
    var objectsById: [String: SuiObjectInfo] = [:]
    var functionSignature: SuiMoveFunctionSignature?
    var referenceGasPriceValue: UInt64 = 1000
    var gasCostSummaryValue = SuiGasCostSummary(computationCost: 1000, storageCost: 100, storageRebate: 0)
    private(set) var ownedCoinsRequests: [(address: SuiAddress, coinType: String)] = []

    func ownedCoins(of address: SuiAddress, coinType: String) async throws -> [SuiCoinObject] {
        ownedCoinsRequests.append((address, coinType))
        return coinsByType[coinType] ?? []
    }

    func objects(ids: [String]) async throws -> [SuiObjectInfo] {
        ids.compactMap { objectsById[$0] }
    }

    func moveFunction(package: String, module: String, name: String) async throws -> SuiMoveFunctionSignature {
        guard let functionSignature else {
            throw ReefrError.invalidData
        }

        return functionSignature
    }

    func referenceGasPrice() async throws -> UInt64 {
        referenceGasPriceValue
    }

    func gasCostSummary(transactionData: Data) async throws -> SuiGasCostSummary {
        gasCostSummaryValue
    }
}
