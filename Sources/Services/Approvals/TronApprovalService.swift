//
//  TronApprovalService.swift
//  Reefr Wallet
//
//  Created by Andrey Yurkevich on 24.10.26.
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import BigInt
import Foundation
import WalletKit

// MARK: - TronApprovalService

/// Discovers a Tron account's TRC-20 approvals from its own `approve` calls on TronGrid
/// (confirmed against the live `allowance`) and revokes them with `approve(spender, 0)`
/// (ADR-048). The scan cursor is the newest scanned `block_timestamp`, in milliseconds.
final class TronApprovalService: @unchecked Sendable {
    private static let approveSelector = "095ea7b3"
    private static let feeLimit: UInt64 = 100_000_000
    private static let pageSize = 200
    private static let receiptPollInterval = Duration.seconds(3)
    private static let receiptPollLimit = 40

    private lazy var clientProvider = DI.injectOrFail(BlockchainClientProvider.self)
    private let databaseService: DatabaseService
    private let refreshQueue = ApprovalRefreshQueue()

    init(databaseService: DatabaseService? = nil) {
        self.databaseService = databaseService ?? DI.injectOrFail(DatabaseService.self)
    }

    func enqueueRefresh(_ account: Account) {
        guard case .tron = account.blockchain else {
            return
        }

        refreshQueue.enqueue(account) { [self] account in
            try await updateApprovals(account)
        }
    }

    /// Re-reads `account`'s approvals: new `approve` calls since the last scan are merged with
    /// the stored ones, and each is re-checked against its live `allowance`.
    func updateApprovals(_ account: Account) async throws {
        try await RequestLane.$current.withValue(.approvals) {
            try await scanApprovals(account)
        }
    }

    private func scanApprovals(_ account: Account) async throws {
        let client = try clientProvider.tronClient(for: account)
        let owner = try TronAddress(string: account.address)
        let scanKey = ApprovalScanState.allTokensKey
        let scanned = try await databaseService.fetchApprovalScans(account: account)[scanKey]?.block

        var candidates: [String: ApprovalCandidate] = [:]

        for approval in try await databaseService.fetchApprovals(account: account) {
            guard let token = approval.token.address else {
                continue
            }

            candidates["\(token)-\(approval.spender)"] = ApprovalCandidate(
                approvedAt: approval.approvedAt, spender: approval.spender, token: token
            )
        }

        let (calls, newest) = try await approveCalls(client: client, owner: owner, since: scanned)

        for call in calls {
            candidates["\(call.token)-\(call.spender)"] = ApprovalCandidate(
                approvedAt: call.timestamp, spender: call.spender, token: call.token
            )
        }

        printVerbose("Approvals \(account.name): since \(scanned.map(String.init) ?? "start"), \(calls.count) new approve calls, \(candidates.count) candidates")

        var updates: [ApprovalUpdate] = []
        var tokens: [String: Token] = [:]

        for candidate in candidates.values {
            guard let token = try? TronAddress(string: candidate.token),
                  let spender = try? TronAddress(string: candidate.spender),
                  let allowance = try? await allowance(client: client, owner: owner, spender: spender, token: token),
                  allowance > 0 else {
                continue
            }

            if tokens[candidate.token] == nil {
                tokens[candidate.token] = try? await resolveToken(candidate.token, account: account, client: client)
            }

            guard let token = tokens[candidate.token] else {
                continue
            }

            updates.append(ApprovalUpdate(
                allowance: allowance, approvedAt: candidate.approvedAt, spender: candidate.spender, token: token
            ))
        }

        printVerbose("Approvals \(account.name): \(updates.count) active, cursor \(newest ?? scanned ?? 0)")

        try await databaseService.replaceApprovals(
            account: account,
            updates: updates,
            scans: [scanKey: ApprovalScanState(block: newest ?? scanned)]
        )
    }

    func prepareRevoke(_ approval: TokenApproval, account: Account) async throws -> PreparedApprovalRevoke {
        let client = try clientProvider.tronClient(for: account)
        let raw = try await buildRevoke(approval, account: account, client: client, feeLimit: Self.feeLimit)
        let fee = try await client.estimateFee(for: raw)
        let fees = Fees(nativeFeeReserve: String(fee.burnedSun), tronFee: fee, tronFeeLimit: String(Self.feeLimit))
        return PreparedApprovalRevoke(approval: approval, fees: fees, transaction: .tron(raw))
    }

    func submitRevoke(
        _ prepared: PreparedApprovalRevoke,
        account: Account,
        fees: Fees,
        onSending: @MainActor @Sendable () -> Void
    ) async throws {
        guard case let .tron(quoted) = prepared.transaction,
              let feeLimit = UInt64(fees.tronFeeLimit ?? String(Self.feeLimit)) else {
            throw ReefrError.invalidData
        }

        let client = try clientProvider.tronClient(for: account)
        let transaction = if feeLimit == quoted.feeLimit {
            quoted
        } else {
            try await buildRevoke(prepared.approval, account: account, client: client, feeLimit: feeLimit)
        }

        let transactionService = DI.injectOrFail(TransactionService.self)
        try checkExpiration(transaction)

        let request = try transaction.signingEnvelope()
        let signature = try await transactionService.signTransaction(request, account: account)
        try checkExpiration(transaction)

        await onSending()
        let hash = try await transactionService.sendTransaction(request, signature, account: account)
        try await waitForSuccess(hash, client: client)
        try await databaseService.deleteApproval(id: prepared.approval.id)
    }
}

// MARK: - Chain reads

private extension TronApprovalService {
    struct ApproveCall {
        let spender: String
        let timestamp: Date?
        let token: String
    }

    func allowance(client: TronClient, owner: TronAddress, spender: TronAddress, token: TronAddress) async throws
        -> BigUInt {
        let response = try await post(client, "wallet/triggerconstantcontract", [
            "contract_address": token.string,
            "function_selector": "allowance(address,address)",
            "owner_address": owner.string,
            "parameter": Self.word(owner) + Self.word(spender),
            "visible": true
        ])

        guard let hex = response["constant_result"]?[0]?.stringValue, let value = BigUInt(hex, radix: 16) else {
            throw ReefrError.invalidData
        }

        return value
    }

    func buildRevoke(
        _ approval: TokenApproval,
        account: Account,
        client: TronClient,
        feeLimit: UInt64
    ) async throws -> TronRawTransaction {
        guard feeLimit <= UInt64(Int64.max) else {
            throw ReefrError.invalidData
        }

        guard let tokenAddress = approval.token.address else {
            throw ReefrError.invalidData
        }

        let sender = try TronAddress(string: account.address)
        let spender = try TronAddress(string: approval.spender)
        let token = try TronAddress(string: tokenAddress)
        let parameter = Self.word(spender) + String(repeating: "0", count: 64)

        let response = try await post(client, "wallet/triggersmartcontract", [
            "contract_address": tokenAddress,
            "fee_limit": feeLimit,
            "function_selector": "approve(address,uint256)",
            "owner_address": sender.string,
            "parameter": parameter,
            "visible": true
        ])

        // The node nests the transaction under `transaction`.
        let transaction = response["transaction"] ?? response

        guard transaction["raw_data_hex"] != nil else {
            throw TronApprovalError.api("The node did not build the revoke transaction")
        }

        let raw = try TronRawTransaction(envelope: transaction.encoded())
        guard case let .triggerSmartContract(owner, contract, callValue, data) = raw.contract,
              owner == sender, contract == token, callValue == 0,
              (raw.feeLimit ?? 0) == feeLimit, raw.memo == nil,
              data.map({ String(format: "%02x", $0) }).joined() == Self.approveSelector + parameter
        else {
            throw ReefrError.invalidData
        }

        return raw
    }

    func checkExpiration(_ transaction: TronRawTransaction) throws {
        guard Double(transaction.expiration) / 1000 > Date.now.timeIntervalSince1970 else {
            throw RevokeExpiredError()
        }
    }

    /// The owner's successful `approve` calls with block timestamp ≥ `since` (oldest first),
    /// plus the newest timestamp seen.
    func approveCalls(client: TronClient, owner: TronAddress, since: UInt64?) async throws
        -> (calls: [ApproveCall], newest: UInt64?) {
        var calls: [ApproveCall] = []
        var newest = since
        var fingerprint: String?

        repeat {
            var query = [
                URLQueryItem(name: "limit", value: String(Self.pageSize)),
                URLQueryItem(name: "only_confirmed", value: "true"),
                URLQueryItem(name: "only_from", value: "true"),
                URLQueryItem(name: "order_by", value: "block_timestamp,asc")
            ]

            if let since {
                query.append(URLQueryItem(name: "min_timestamp", value: String(since)))
            }

            if let fingerprint {
                query.append(URLQueryItem(name: "fingerprint", value: fingerprint))
            }

            let page = try JSONValue(
                data: await client.relay(path: "v1/accounts/\(owner.string)/transactions", query: query, body: nil)
            )

            for item in page["data"]?.arrayValue ?? [] {
                if let stamp = item["block_timestamp"]?.numberValue.map(UInt64.init) {
                    newest = max(newest ?? 0, stamp)
                }

                if let call = Self.approveCall(item) {
                    calls.append(call)
                }
            }

            fingerprint = page["meta"]?["fingerprint"]?.stringValue
        } while fingerprint != nil

        return (calls, newest)
    }

    static func approveCall(_ item: JSONValue) -> ApproveCall? {
        guard item["ret"]?[0]?["contractRet"]?.stringValue == "SUCCESS",
              let value = item["raw_data"]?["contract"]?[0]?["parameter"]?["value"],
              let data = value["data"]?.stringValue,
              data.hasPrefix(approveSelector), data.count >= 72,
              let contract = value["contract_address"]?.stringValue,
              let token = address(hex: contract),
              let spender = address(hex: "41" + data.dropFirst(8 + 24).prefix(40)) else {
            return nil
        }

        return ApproveCall(
            spender: spender,
            timestamp: item["block_timestamp"]?.numberValue.map { Date(timeIntervalSince1970: $0 / 1000) },
            token: token
        )
    }

    func resolveToken(_ address: String, account: Account, client: TronClient) async throws -> Token {
        if let stored = try await databaseService.fetchToken(tokenAddress: address, blockchain: account.blockchain) {
            return stored
        }

        let info = try await client.getTokenInfo(address)

        return Token(address: address, blockchain: account.blockchain, tokenInfo: info)
    }

    func waitForSuccess(_ hash: String, client: TronClient) async throws {
        for _ in 0..<Self.receiptPollLimit {
            let info = try? await post(client, "wallet/gettransactioninfobyid", ["value": hash])

            if let result = info?["receipt"]?["result"]?.stringValue {
                guard result == "SUCCESS" else {
                    throw TronApprovalError.api("Revoke transaction \(hash) failed: \(result)")
                }

                return
            }

            try await _Concurrency.Task.sleep(for: Self.receiptPollInterval)
        }

        throw TronApprovalError.api("Revoke transaction \(hash) not confirmed yet")
    }

    func post(_ client: TronClient, _ path: String, _ body: [String: Any]) async throws -> JSONValue {
        try JSONValue(data: await client.relay(path: path, body: JSONSerialization.data(withJSONObject: body)))
    }
}

// MARK: - Encoding

private extension TronApprovalService {
    /// The address as a 32-byte ABI word (the leading `0x41` is dropped).
    static func word(_ address: TronAddress) -> String {
        String(repeating: "0", count: 24) + address.rawBytes.dropFirst().map { String(format: "%02x", $0) }.joined()
    }

    /// Base58 form of a 21-byte hex address (`41…`).
    static func address(hex: String) -> String? {
        guard hex.count == 42 else {
            return nil
        }

        var bytes = Data()
        var index = hex.startIndex

        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)

            guard let byte = UInt8(hex[index..<next], radix: 16) else {
                return nil
            }

            bytes.append(byte)
            index = next
        }

        return (try? TronAddress(rawBytes: bytes))?.string
    }
}

private enum TronApprovalError: LocalizedError {
    case api(String)

    var errorDescription: String? {
        switch self {
        case let .api(message):
            String(localized: .tronGridError(message))
        }
    }
}
