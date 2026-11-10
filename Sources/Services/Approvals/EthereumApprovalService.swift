// swiftlint:disable file_length
//
//  EthereumApprovalService.swift
//  Reefr Wallet
//
//  Created by Andrey Yurkevich on 24.10.26.
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import Alamofire
import Moya
import WalletKit

/// Discovers and revokes EVM token approvals (ADR-048).
final class EthereumApprovalService: @unchecked Sendable {
    private static let approvalTopic = "0x" + EthereumABI
        .keccak256(Data("Approval(address,address,uint256)".utf8))
        .map { String(format: "%02x", $0) }
        .joined()

    private static let logsPageSize = 1000
    private static let maxLogPages = 10
    private static let rateLimitRetries = 5
    private static let receiptPollInterval = Duration.seconds(2)
    private static let receiptPollLimit = 90
    /// Blocks re-read below the last scanned one, so a reorg can't hide a log.
    private static let reorgOverlap: UInt64 = 32
    private static let origin = "https://api.etherscan.io"

    private lazy var clientProvider = DI.injectOrFail(BlockchainClientProvider.self)
    private let databaseService: DatabaseService
    private let provider: MoyaProvider<ApprovalLogsAPI>
    private let refreshQueue = ApprovalRefreshQueue()
    private let userDefaults: UserDefaults

    init(databaseService: DatabaseService? = nil, userDefaults: UserDefaults = .standard) {
        self.databaseService = databaseService ?? DI.injectOrFail(DatabaseService.self)
        self.userDefaults = userDefaults

        provider = RateGateRegistry.shared.makeProvider(origin: Self.origin, provider: .etherscan)
    }

    func enqueueRefresh(_ account: Account) {
        guard supports(account) else {
            return
        }

        refreshQueue.enqueue(account) { [self] account in
            try await updateApprovals(account)
        }
    }

    func supports(_ account: Account) -> Bool {
        EtherscanTransactionHistorySource(userDefaults: userDefaults).supports(account)
    }

    /// Rescans from the reorg window and checks every candidate's live allowance.
    func updateApprovals(_ account: Account) async throws {
        try await RequestLane.$current.withValue(.approvals) {
            try await scanApprovals(account)
        }
    }

    private func scanApprovals(_ account: Account) async throws {
        guard case let .evm(chain) = account.blockchain else {
            throw ReefrError.notSupported
        }

        let client = try clientProvider.ethereumClient(for: account)
        let owner = try EthereumAddress(string: account.address)
        let head = try await blockNumber(client)
        let scanKey = ApprovalScanState.allTokensKey
        let scanned = try await databaseService.fetchApprovalScans(account: account)[scanKey]?.block
        let from = scanned.map { $0 >= Self.reorgOverlap ? $0 - Self.reorgOverlap + 1 : 0 } ?? 0

        // Keyed by token + spender; stored rows first, so a newer log replaces them.
        var candidates: [String: ApprovalCandidate] = [:]

        for approval in try await databaseService.fetchApprovals(account: account) {
            guard let token = approval.token.address else {
                continue
            }

            candidates["\(token.lowercased())-\(approval.spender.lowercased())"] = ApprovalCandidate(
                approvedAt: approval.approvedAt, spender: approval.spender, token: token
            )
        }

        for log in try await latestApprovals(chainId: chain.chainId, owner: account.address, from: from, to: head) {
            candidates[log.id.lowercased()] = ApprovalCandidate(
                approvedAt: log.timestamp, spender: log.spender, token: log.token
            )
        }

        let updates = await liveApprovals(candidates, account: account, client: client, owner: owner)

        printVerbose("Approvals \(account.name): from block \(from), \(candidates.count) candidates, \(updates.count) active")

        try await databaseService.replaceApprovals(
            account: account,
            updates: updates,
            scans: [scanKey: ApprovalScanState(block: head)]
        )
    }

    func prepareRevoke(_ approval: TokenApproval, account: Account) async throws -> PreparedApprovalRevoke {
        guard let tokenAddress = approval.token.address else {
            throw ReefrError.invalidData
        }

        let client = try clientProvider.ethereumClient(for: account)
        let feeService = DI.injectOrFail(FeeEstimationService.self)
        let sender = try EthereumAddress(string: account.address)
        let token = try EthereumAddress(string: tokenAddress)
        let spender = try EthereumAddress(string: approval.spender)
        let data = EthereumABI.encodeCall(
            selector: EthereumABI.selector("approve(address,uint256)"),
            parameters: [.address(spender), .uint256(0)]
        )

        async let nonce = client.nonce(of: sender)
        let (gasLimit, rates) = try await feeService.estimateCall(
            to: token, value: 0, data: data, gasLimit: nil, account: account
        )

        let transaction = UnsignedEIP1559Transaction(
            nonce: try await BigUInt(nonce),
            maxPriorityFeePerGas: rates.maxPriorityFeePerGas,
            maxFeePerGas: rates.maxFeePerGas,
            gasLimit: gasLimit,
            to: token,
            value: 0,
            data: data,
            chainId: client.chainId
        )

        let fees = feeService.ethereumFees(
            rates: rates,
            gasLimit: gasLimit,
            maxFee: transaction.maxFeePerGas,
            maxPriorityFee: transaction.maxPriorityFeePerGas
        )

        return PreparedApprovalRevoke(approval: approval, fees: fees, transaction: .ethereum(transaction))
    }

    func submitRevoke(
        _ prepared: PreparedApprovalRevoke,
        account: Account,
        fees: Fees,
        onSending: @MainActor @Sendable () -> Void
    ) async throws {
        guard case let .ethereum(transaction) = prepared.transaction,
              let maxFee = fees.ethereumMaxFee.flatMap({ BigUInt($0) }),
              let priorityFee = fees.ethereumMaxPriorityFee.flatMap({ BigUInt($0) }),
              maxFee > 0, maxFee.bitWidth <= 256, priorityFee <= maxFee else {
            throw ReefrError.invalidData
        }

        let client = try clientProvider.ethereumClient(for: account)
        let sender = try EthereumAddress(string: account.address)
        guard try await BigUInt(client.nonce(of: sender)) == transaction.nonce else {
            throw RevokeExpiredError()
        }

        let transactionService = DI.injectOrFail(TransactionService.self)
        let request = UnsignedEIP1559Transaction(
            nonce: transaction.nonce,
            maxPriorityFeePerGas: priorityFee,
            maxFeePerGas: maxFee,
            gasLimit: transaction.gasLimit,
            to: transaction.to,
            value: transaction.value,
            data: transaction.data,
            chainId: transaction.chainId
        ).signingData

        let signature = try await transactionService.signTransaction(request, account: account)
        await onSending()
        let hash = try await transactionService.sendTransaction(request, signature, account: account)
        try await waitForSuccess(hash, client: client)
        try await databaseService.deleteApproval(id: prepared.approval.id)
    }
}

private extension EthereumApprovalService {
    func waitForSuccess(_ hash: String, client: EthereumRPCClient) async throws {
        let params = try JSONValue.array([.string(hash)]).encoded()

        for _ in 0..<Self.receiptPollLimit {
            let receipt = try? JSONValue(
                data: await client.request(method: "eth_getTransactionReceipt", params: params)
            )

            if let status = receipt?["status"]?.stringValue {
                guard status == "0x1" else {
                    throw RevokeReceiptError("Revoke transaction \(hash) reverted")
                }

                return
            }

            try await _Concurrency.Task.sleep(for: Self.receiptPollInterval)
        }

        throw RevokeReceiptError("Revoke transaction \(hash) not confirmed yet")
    }

    /// The candidates whose live `allowance` is still positive.
    func liveApprovals(
        _ candidates: [String: ApprovalCandidate],
        account: Account,
        client: EthereumRPCClient,
        owner: EthereumAddress
    ) async -> [ApprovalUpdate] {
        var updates: [ApprovalUpdate] = []
        var tokens: [String: Token] = [:]

        for candidate in candidates.values {
            guard let token = try? EthereumAddress(string: candidate.token),
                  let spender = try? EthereumAddress(string: candidate.spender) else {
                continue
            }

            let data = EthereumABI.encodeCall(
                selector: EthereumABI.selector("allowance(address,address)"),
                parameters: [.address(owner), .address(spender)]
            )

            guard let word = try? await EthereumABI.words(client.call(to: token, data: data)).first else {
                continue
            }

            let allowance = EthereumABI.decodeUInt256(word)

            guard allowance > 0 else {
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

        return updates
    }

    func resolveToken(_ address: String, account: Account, client: EthereumRPCClient) async throws -> Token {
        if let stored = try await databaseService.fetchToken(tokenAddress: address, blockchain: account.blockchain) {
            return stored
        }

        let info = try await client.getTokenInfo(address)

        return Token(address: address, blockchain: account.blockchain, tokenInfo: info)
    }
}

// MARK: - Chain reads

private extension EthereumApprovalService {
    func blockNumber(_ client: EthereumRPCClient) async throws -> UInt64 {
        let value = try JSONValue(
            data: await client.request(method: "eth_blockNumber", params: JSONValue.array([]).encoded())
        )

        guard let hex = value.stringValue, let number = UInt64(hex.dropFirst(2), radix: 16) else {
            throw ReefrError.invalidData
        }

        return number
    }

    static func topic(for address: String) -> String {
        "0x" + String(repeating: "0", count: 24) + address.dropFirst(2).lowercased()
    }
}

// MARK: - Logs

private extension EthereumApprovalService {
    var apiKey: String {
        userDefaults
            .string(forKey: EtherscanTransactionHistorySource.apiKeyDefaultsKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        ?? ""
    }

    /// The most recent `Approval` log per (token, spender) in `from...to`. ERC-721 `Approval`
    /// shares the topic hash but indexes the token id too (4 topics), so it's skipped.
    ///
    /// Etherscan returns oldest first and serves only the first 10,000 results of a query, so
    /// a full last page moves the window's start up to the newest block seen and continues.
    func latestApprovals(chainId: UInt64, owner: String, from: UInt64, to: UInt64) async throws -> [ApprovalLog] {
        let ownerTopic = Self.topic(for: owner)
        var latest: [String: ApprovalLog] = [:]
        var start = from
        var page = 1

        while start <= to {
            let logs = try await logs(
                .logs(
                    apiKey: apiKey,
                    chainId: chainId,
                    from: start,
                    ownerTopic: ownerTopic,
                    page: page,
                    to: to,
                    topic0: Self.approvalTopic
                )
            )

            for log in logs.compactMap(ApprovalLog.init) {
                if let existing = latest[log.id], log < existing {
                    continue
                }

                latest[log.id] = log
            }

            guard logs.count == Self.logsPageSize else {
                break
            }

            if page < Self.maxLogPages {
                page += 1
            } else {
                guard let newest = logs.compactMap(ApprovalLog.init).map(\.blockNumber).max(), newest > start else {
                    throw EthereumApprovalServiceError.api("Too many approval logs in block \(start)")
                }

                start = newest
                page = 1
            }
        }

        return Array(latest.values)
    }

    /// Etherscan reports rate limits in-band (HTTP 200), invisible to the interceptor; a
    /// concurrent history backfill hits them often. Push the shared gate and retry (ADR-026).
    func logs(_ target: ApprovalLogsAPI) async throws -> [ApprovalLogsResponse.Log] {
        for attempt in 0..<Self.rateLimitRetries {
            let response: ApprovalLogsResponse = try await provider.request(target)

            guard response.isRateLimited else {
                await RateGateRegistry.shared.reportSuccess(origin: Self.origin, provider: .etherscan)
                return try response.result()
            }

            await RateGateRegistry.shared.penalize(
                origin: Self.origin,
                provider: .etherscan,
                by: .seconds(RateLimitRetryPolicy.backoffSeconds(attempt: attempt))
            )
        }

        let response: ApprovalLogsResponse = try await provider.request(target)

        if !response.isRateLimited {
            await RateGateRegistry.shared.reportSuccess(origin: Self.origin, provider: .etherscan)
        }

        return try response.result()
    }
}

private struct ApprovalLog {
    let blockNumber: UInt64
    let logIndex: UInt64
    let spender: String
    var timestamp: Date?
    let token: String

    var id: String {
        "\(token)-\(spender)"
    }

    var order: [UInt64] {
        [blockNumber, logIndex]
    }

    init?(_ raw: ApprovalLogsResponse.Log) {
        guard raw.topics.count == 3,
              let spender = try? EthereumAddress(string: "0x" + raw.topics[2].suffix(40)) else {
            return nil
        }

        blockNumber = Self.number(raw.blockNumber) ?? 0
        logIndex = Self.number(raw.logIndex) ?? 0
        self.spender = spender.string
        timestamp = Self.number(raw.timeStamp).map { Date(timeIntervalSince1970: TimeInterval($0)) }
        token = (try? EthereumAddress(string: raw.address).string) ?? raw.address
    }

    private static func number(_ hex: String?) -> UInt64? {
        hex.flatMap { UInt64($0.dropFirst(2), radix: 16) }
    }
}

extension ApprovalLog: Comparable {
    static func < (lhs: ApprovalLog, rhs: ApprovalLog) -> Bool {
        lhs.order.lexicographicallyPrecedes(rhs.order)
    }

    static func == (lhs: ApprovalLog, rhs: ApprovalLog) -> Bool {
        lhs.order == rhs.order
    }
}

private enum ApprovalLogsAPI {
    case logs(apiKey: String, chainId: UInt64, from: UInt64, ownerTopic: String, page: Int, to: UInt64, topic0: String)
}

extension ApprovalLogsAPI: TargetType {
    var baseURL: URL {
        URL(string: "https://api.etherscan.io/v2/api")!
    }

    var headers: [String: String]? {
        nil
    }

    var method: Moya.Method {
        .get
    }

    var path: String {
        ""
    }

    var sampleData: Data {
        Data()
    }

    var task: Task {
        switch self {
        case let .logs(apiKey, chainId, from, ownerTopic, page, to, topic0):
            .requestParameters(
                parameters: [
                    "action": "getLogs",
                    "apikey": apiKey,
                    "chainid": chainId,
                    "fromBlock": from,
                    "module": "logs",
                    "offset": 1000,
                    "page": page,
                    "toBlock": to,
                    "topic0": topic0,
                    "topic0_1_opr": "and",
                    "topic1": ownerTopic
                ],
                encoding: URLEncoding.queryString
            )
        }
    }

    var validationType: ValidationType {
        .successCodes
    }
}

private struct ApprovalLogsResponse: Decodable {
    struct Log: Decodable {
        let address: String
        let blockNumber: String
        let logIndex: String?
        let timeStamp: String?
        let topics: [String]
    }

    private let logs: [Log]?
    private let message: String?
    private let text: String?

    private enum CodingKeys: String, CodingKey {
        case message
        case result
    }

    var isRateLimited: Bool {
        logs == nil && text?.localizedCaseInsensitiveContains("rate limit") == true
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        message = try container.decodeIfPresent(String.self, forKey: .message)
        logs = try? container.decode([Log].self, forKey: .result)
        text = try? container.decode(String.self, forKey: .result)
    }

    func result() throws -> [Log] {
        if let logs {
            return logs
        }

        if message == "No records found" {
            return []
        }

        throw EthereumApprovalServiceError.api(text ?? message ?? "Unknown API error")
    }
}

private enum EthereumApprovalServiceError: LocalizedError {
    case api(String)

    var errorDescription: String? {
        switch self {
        case let .api(message):
            String(localized: .etherscanError(message))
        }
    }
}

private struct RevokeReceiptError: LocalizedError {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? {
        message
    }
}
