//
//  DefiIndexedLogs.swift
//  Reefr Wallet
//
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import Alamofire
import Foundation
import Moya
import WalletKit

/// A ``DefiEVMReader`` whose log queries fall back to block-explorer indexers.
/// Public RPCs serve `eth_getLogs` only for recent blocks ("archive requests
/// require a token"), while position history goes back to the mint. See ADR-073.
struct IndexedLogsDefiEVMReader: DefiEVMReader {
    /// Indexers answer any range in one query, so the scanner can ask for wide ones.
    static let indexedLogRange: UInt64 = 50_000_000

    let base: any DefiEVMReader
    let indexers: [EtherscanCompatibleLogs]

    var preferredLogRange: UInt64 {
        indexers.isEmpty ? base.preferredLogRange : Self.indexedLogRange
    }

    func block(_ tag: BlockTag) async throws -> BlockRef? {
        try await base.block(tag)
    }

    func call(_ calls: [EVMCall], at block: BlockRef) async throws -> [EVMCallResult] {
        try await base.call(calls, at: block)
    }

    func logs(address: EthereumAddress, topics: [[String]?], from: UInt64, to: UInt64) async throws -> [EVMLog] {
        let nodeError: any Error

        do {
            return try await base.logs(address: address, topics: topics, from: from, to: to)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            nodeError = error
        }

        for indexer in indexers {
            do {
                return try await withBlockHashes(indexer.logs(address: address, topics: topics, from: from, to: to))
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                printVerbose("DeFi logs from \(indexer.name): \(error)")
            }
        }

        throw nodeError
    }

    /// Fills hashes an indexer left out from the node's headers, which aren't archive-gated.
    private func withBlockHashes(_ logs: [EVMLog]) async throws -> [EVMLog] {
        var hashes: [UInt64: String] = [:]
        var result: [EVMLog] = []

        for log in logs {
            guard log.blockHash.isEmpty else {
                result.append(log)
                continue
            }

            if hashes[log.blockNumber] == nil {
                hashes[log.blockNumber] = try await base.block(.number(log.blockNumber))?.hash
            }

            guard let hash = hashes[log.blockNumber] else {
                throw BlockchainClientError.decodingFailed(reason: "no block \(log.blockNumber)")
            }

            result.append(EVMLog(
                blockHash: hash,
                blockNumber: log.blockNumber,
                data: log.data,
                logIndex: log.logIndex,
                topics: log.topics,
                transactionHash: log.transactionHash
            ))
        }

        return result
    }
}

extension IndexedLogsDefiEVMReader {
    /// The node, then Etherscan when it has a key for the chain, then the chain's Blockscout.
    static func live(account: Account) throws -> IndexedLogsDefiEVMReader {
        let client = try DI.injectOrFail(BlockchainClientProvider.self).ethereumClient(for: account)
        var indexers: [EtherscanCompatibleLogs] = []

        guard case let .evm(chain) = account.blockchain else {
            return IndexedLogsDefiEVMReader(base: LiveDefiEVMReader(client: client), indexers: [])
        }

        let apiKey = UserDefaults.standard
            .string(forKey: EtherscanTransactionHistorySource.apiKeyDefaultsKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        if !apiKey.isEmpty, EtherscanTransactionHistorySource.supportedChainIds.contains(chain.chainId) {
            indexers.append(.etherscan(apiKey: apiKey, chainId: chain.chainId))
        }

        if let apiV2 = BlockscoutTransactionHistorySource.defaultAPIBaseURLs[chain.chainId] {
            indexers.append(.blockscout(apiV2: apiV2))
        }

        return IndexedLogsDefiEVMReader(base: LiveDefiEVMReader(client: client), indexers: indexers)
    }
}

// MARK: - Etherscan-compatible logs

/// `module=logs&action=getLogs` on Etherscan v2 or a Blockscout instance's `/api`.
struct EtherscanCompatibleLogs: Sendable {
    /// Both APIs return at most 1,000 logs per query.
    static let pageSize = 1_000

    let baseURL: URL
    let fixedParameters: [String: String]
    let name: String
    let origin: String
    let providerKind: ProviderKind

    static func blockscout(apiV2: URL) -> Self {
        // `https://host/api/v2` → `https://host/api`.
        let api = apiV2.lastPathComponent == "v2" ? apiV2.deletingLastPathComponent() : apiV2

        return Self(
            baseURL: api,
            fixedParameters: [:],
            name: "Blockscout",
            origin: BlockscoutTransactionHistorySource.origin(of: apiV2),
            providerKind: .blockscout
        )
    }

    static func etherscan(apiKey: String, chainId: UInt64) -> Self {
        Self(
            // swiftlint:disable:next force_unwrapping
            baseURL: URL(string: "https://api.etherscan.io/v2/api")!,
            fixedParameters: ["apikey": apiKey, "chainid": String(chainId)],
            name: "Etherscan",
            origin: "https://api.etherscan.io",
            providerKind: .etherscan
        )
    }

    /// All logs matching `topics`; an OR list in a position becomes one query per option.
    func logs(address: EthereumAddress, topics: [[String]?], from: UInt64, to: UInt64) async throws -> [EVMLog] {
        let provider: MoyaProvider<DefiLogsAPI> = RateGateRegistry.shared.makeProvider(
            origin: origin,
            provider: providerKind
        )

        var logs: [EVMLog] = []

        for combination in Self.combinations(topics) {
            logs += try await allPages(provider: provider, address: address, topics: combination, from: from, to: to)
        }

        return logs.sorted { ($0.blockNumber, $0.logIndex) < ($1.blockNumber, $1.logIndex) }
    }

    /// A full page restarts from its last block; the overlap is deduplicated.
    private func allPages(
        provider: MoyaProvider<DefiLogsAPI>,
        address: EthereumAddress,
        topics: [String?],
        from: UInt64,
        to: UInt64
    ) async throws -> [EVMLog] {
        var logs: [String: EVMLog] = [:]
        var start = from

        while true {
            let page = try await request(provider: provider, parameters: parameters(address, topics, start, to))

            for log in page {
                logs["\(log.transactionHash)|\(log.logIndex)|\(log.topics)|\(log.data.hexEncoded)"] = log
            }

            guard page.count >= Self.pageSize, let last = page.map(\.blockNumber).max(), last > start else {
                return Array(logs.values)
            }

            start = last
        }
    }

    private func parameters(
        _ address: EthereumAddress,
        _ topics: [String?],
        _ from: UInt64,
        _ to: UInt64
    ) -> [String: String] {
        var parameters = fixedParameters.merging([
            "action": "getLogs",
            "address": address.string.lowercased(),
            "fromBlock": String(from),
            "module": "logs",
            "toBlock": String(to)
        ]) { $1 }

        let present = topics.enumerated().compactMap { index, topic in topic.map { (index, $0) } }

        for (index, topic) in present {
            parameters["topic\(index)"] = topic
        }

        for (offset, first) in present.enumerated() {
            for second in present.dropFirst(offset + 1) {
                parameters["topic\(first.0)_\(second.0)_opr"] = "and"
            }
        }

        return parameters
    }

    private func request(provider: MoyaProvider<DefiLogsAPI>, parameters: [String: String]) async throws -> [EVMLog] {
        for attempt in 0 ..< 3 {
            do {
                let response: CompatibleLogsResponse = try await provider.request(
                    DefiLogsAPI(baseURL: baseURL, parameters: parameters)
                )

                await RateGateRegistry.shared.reportSuccess(origin: origin, provider: providerKind)
                return try response.logs()
            } catch CompatibleLogsError.rateLimited where attempt < 2 {
                await RateGateRegistry.shared.penalize(
                    origin: origin,
                    provider: providerKind,
                    by: .seconds(RateLimitRetryPolicy.backoffSeconds(attempt: attempt))
                )
            }
        }

        throw CompatibleLogsError.rateLimited
    }

    static func combinations(_ topics: [[String]?]) -> [[String?]] {
        topics.reduce([[]]) { partial, options in
            guard let options else {
                return partial.map { $0 + [nil] }
            }

            return partial.flatMap { prefix in options.map { prefix + [$0] } }
        }
    }
}

private struct DefiLogsAPI: TargetType {
    let baseURL: URL
    let parameters: [String: String]

    var headers: [String: String]? {
        ["Accept": "application/json"]
    }

    var method: Moya.Method {
        .get
    }

    var path: String {
        ""
    }

    var task: Moya.Task {
        .requestParameters(parameters: parameters, encoding: URLEncoding.queryString)
    }

    var validationType: ValidationType {
        .successCodes
    }
}

enum CompatibleLogsError: Error {
    case message(String)
    case rateLimited
}

struct CompatibleLogsResponse: Decodable {
    struct Log: Decodable {
        let blockHash: String?
        let blockNumber: String
        let data: String
        let logIndex: String?
        let topics: [String?]
        let transactionHash: String
    }

    let message: String?
    let result: [Log]?
    let resultMessage: String?

    enum CodingKeys: String, CodingKey {
        case message, result
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        message = try container.decodeIfPresent(String.self, forKey: .message)
        result = try? container.decode([Log].self, forKey: .result)
        resultMessage = try? container.decode(String.self, forKey: .result)
    }

    func logs() throws -> [EVMLog] {
        guard let result else {
            let text = resultMessage ?? message ?? "Unknown API error"

            let isEmpty = ["no records found", "no logs found"].contains { text.localizedCaseInsensitiveContains($0) }

            if isEmpty {
                return []
            }

            if ["rate limit", "too many requests"].contains(where: { text.localizedCaseInsensitiveContains($0) }) {
                throw CompatibleLogsError.rateLimited
            }

            throw CompatibleLogsError.message(text)
        }

        return try result.map { log in
            try EVMLog(
                blockHash: log.blockHash?.lowercased() ?? "",
                blockNumber: Self.number(log.blockNumber),
                data: Data(hexString: log.data),
                logIndex: log.logIndex.flatMap { try? Self.number($0) } ?? 0,
                topics: log.topics.compactMap { $0?.lowercased() },
                transactionHash: log.transactionHash.lowercased()
            )
        }
    }

    /// Hex (`0x1a`) or decimal.
    private static func number(_ text: String) throws -> UInt64 {
        let value = text.hasPrefix("0x") ? UInt64(text.dropFirst(2), radix: 16) : UInt64(text)

        guard let value else {
            throw BlockchainClientError.decodingFailed(reason: "invalid number \(text)")
        }

        return value
    }
}
