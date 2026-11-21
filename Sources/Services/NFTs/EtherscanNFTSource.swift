//
//  EtherscanNFTSource.swift
//  Reefr Wallet
//
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import Alamofire
import BigInt
import Foundation
import Moya
import WalletKit

/// Replays an EVM account's ERC-721/1155 transfers from Etherscan's
/// `tokennfttx`/`token1155tx`, oldest first from the scan's overlap start.
///
/// Etherscan omits `logIndex`. A transaction with one matching event is
/// keyed `logIndex 0`; one with more is resolved from its receipt, which
/// gives each log's index and batch position. See ADR-072.
/// `@unchecked Sendable`: `MoyaProvider` and `UserDefaults` are thread-safe.
struct EtherscanNFTSource: NFTSource, @unchecked Sendable {
    private static let maxBlock = UInt64(Int64.max)
    private static let origin = "https://api.etherscan.io"
    private static let pageSize = 1000
    private static let transferTopic = "0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef"
    private static let transferBatchTopic = "0x4a39dc06d4c0dbc64b70af90fd698a233a518aa5d07e595d983b8c0526c8f7fb"
    private static let transferSingleTopic = "0xc3d58168c5ae7397731d063d5bbf3d657854427343f4c083240f7aacaa2d0f62"

    private let clientProvider: BlockchainClientProvider
    private let provider: MoyaProvider<EtherscanNFTAPI>
    private let userDefaults: UserDefaults

    let id = NFTSourceId.etherscan

    init(
        clientProvider: BlockchainClientProvider = BlockchainClientProvider(),
        userDefaults: UserDefaults = .standard
    ) {
        self.clientProvider = clientProvider
        self.userDefaults = userDefaults
        provider = RateGateRegistry.shared.makeProvider(origin: Self.origin, provider: .etherscan)
    }

    private var apiKey: String {
        userDefaults
            .string(forKey: EtherscanTransactionHistorySource.apiKeyDefaultsKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    func supports(_ blockchain: Blockchain) -> Bool {
        guard case let .evm(chain) = blockchain else {
            return false
        }

        return EtherscanTransactionHistorySource.supportedChainIds.contains(chain.chainId) && !apiKey.isEmpty
    }

    func scan(account: Account, request: NFTScanRequest) async throws -> NFTScanResult {
        guard case let .evm(chain) = account.blockchain, supports(account.blockchain) else {
            throw URLError(.unsupportedURL)
        }

        var transfers: [EtherscanNFTTransfer] = []

        for (action, standard) in [("tokennfttx", NFTStandard.erc721), ("token1155tx", .erc1155)] {
            transfers += try await allTransfers(
                action: action,
                address: account.address,
                chainId: chain.chainId,
                from: request.overlapStart
            ).map { $0.with(standard: standard) }
        }

        let events = try await events(
            Dictionary(grouping: transfers, by: { $0.hash.lowercased() }),
            owner: account.address,
            account: account
        )

        return .ledger(NFTLedgerScan(
            events: events,
            fromBlock: request.overlapStart,
            metadata: [:],
            scannedBlock: max(request.scannedBlock ?? 0, events.map(\.blockNumber).max() ?? 0)
        ))
    }

    /// Pages ascending from `from`; a page reaching Etherscan's 10,000-result
    /// window restarts at the newest block seen (overlaps are deduplicated by key).
    private func allTransfers(
        action: String,
        address: String,
        chainId: UInt64,
        from: UInt64
    ) async throws -> [EtherscanNFTTransfer] {
        var result: [String: EtherscanNFTTransfer] = [:]
        var startBlock = from
        var page = 1

        while true {
            let items = try await request(.transfers(
                action: action,
                address: address,
                apiKey: apiKey,
                chainId: chainId,
                endBlock: Self.maxBlock,
                offset: Self.pageSize,
                page: page,
                startBlock: startBlock
            ))

            for item in items {
                result[item.identity] = item
            }

            guard items.count == Self.pageSize else {
                return Array(result.values)
            }

            if (page + 1) * Self.pageSize > 10_000 {
                let newest = items.compactMap { UInt64($0.blockNumber) }.max() ?? startBlock
                guard newest > startBlock else {
                    throw EtherscanNFTError.tooManyTransfersInBlock
                }

                startBlock = newest
                page = 1
            } else {
                page += 1
            }
        }
    }

    private func request(_ target: EtherscanNFTAPI) async throws -> [EtherscanNFTTransfer] {
        for attempt in 0..<3 {
            do {
                let response: EtherscanNFTResponse = try await provider.request(target)
                await RateGateRegistry.shared.reportSuccess(origin: Self.origin, provider: .etherscan)
                return response.result
            } catch EtherscanNFTError.rateLimited where attempt < 2 {
                await RateGateRegistry.shared.penalize(
                    origin: Self.origin,
                    provider: .etherscan,
                    by: .seconds(RateLimitRetryPolicy.backoffSeconds(attempt: attempt))
                )
            }
        }

        let response: EtherscanNFTResponse = try await provider.request(target)
        return response.result
    }

    private func events(
        _ byHash: [String: [EtherscanNFTTransfer]],
        owner: String,
        account: Account
    ) async throws -> [NFTTransferEvent] {
        var result: [NFTTransferEvent] = []
        var client: EthereumRPCClient?

        for (hash, transfers) in byHash {
            guard transfers.count > 1 else {
                result += transfers.compactMap { $0.event(logIndex: 0, batchPosition: 0) }
                continue
            }

            if client == nil {
                client = try clientProvider.makeClient(blockchain: account.blockchain, rpcURL: account.rpcURLOverride)
                    as? EthereumRPCClient
            }

            guard let client else {
                throw EtherscanNFTError.receiptUnavailable(hash)
            }

            result += try await receiptEvents(hash: hash, transfers: transfers, owner: owner, client: client)
        }

        return result
    }

    /// The owner's NFT events in a transaction's receipt, with real log indexes
    /// and batch positions.
    func receiptEvents(
        hash: String,
        transfers: [EtherscanNFTTransfer],
        owner: String,
        client: EthereumRPCClient
    ) async throws -> [NFTTransferEvent] {
        let params = try JSONValue.array([.string(hash)]).encoded()
        let receipt = try? JSONValue(data: await client.request(method: "eth_getTransactionReceipt", params: params))

        guard let receipt, let logs = receipt["logs"]?.arrayValue else {
            throw EtherscanNFTError.receiptUnavailable(hash)
        }

        guard let template = transfers.first else {
            return []
        }

        let contracts = Set(transfers.map { $0.contractAddress.lowercased() })
        let decoded = logs.flatMap { Self.decode(log: $0, template: template) }
        let owner = owner.lowercased()

        return decoded.filter {
            contracts.contains($0.contract.lowercased())
                && ($0.from.lowercased() == owner || $0.to.lowercased() == owner)
        }
    }

    /// A decoded receipt log's transfer, before it gets the transaction's fields.
    struct LogTransfer {
        let amount: BigUInt
        let from: String
        let position: Int
        let standard: NFTStandard
        let to: String
        let tokenId: BigUInt
    }

    static func decode(log: JSONValue, template: EtherscanNFTTransfer) -> [NFTTransferEvent] {
        guard let topics = log["topics"]?.arrayValue?.compactMap(\.stringValue), topics.count == 4,
              let contract = log["address"]?.stringValue,
              let logIndex = log["logIndex"]?.stringValue.flatMap(Self.hexInt)
        else {
            return []
        }

        let data = (try? Data(hexString: log["data"]?.stringValue ?? "0x")) ?? Data()

        return transfers(topics: topics, data: data).map { transfer in
            NFTTransferEvent(
                amount: transfer.amount,
                batchPosition: transfer.position,
                blockHash: template.blockHash,
                blockNumber: UInt64(template.blockNumber) ?? 0,
                contract: contract,
                from: transfer.from,
                logIndex: logIndex,
                source: NFTSourceId.etherscan.rawValue,
                standard: transfer.standard,
                to: transfer.to,
                tokenId: transfer.tokenId.description,
                transactionIndex: Int(template.transactionIndex ?? "") ?? 0,
                txHash: template.hash
            )
        }
    }

    /// The ERC-721 `Transfer`, ERC-1155 `TransferSingle` or `TransferBatch`
    /// items of a 4-topic log.
    static func transfers(topics: [String], data: Data) -> [LogTransfer] {
        let topic = topics[0].lowercased()
        let words = EthereumABI.words(data).map { EthereumABI.decodeUInt256($0) }

        func address(_ index: Int) -> String {
            "0x" + String(topics[index].suffix(40))
        }

        if topic == transferTopic {
            let id = BigUInt(String(topics[3].dropFirst(2)), radix: 16) ?? 0
            return [
                LogTransfer(amount: 1, from: address(1), position: 0, standard: .erc721, to: address(2), tokenId: id)
            ]
        }

        if topic == transferSingleTopic, words.count >= 2 {
            return [
                LogTransfer(
                    amount: words[1],
                    from: address(2),
                    position: 0,
                    standard: .erc1155,
                    to: address(3),
                    tokenId: words[0]
                )
            ]
        }

        guard topic == transferBatchTopic else {
            return []
        }

        let (ids, values) = decodeBatch(data)
        return zip(ids, values).enumerated().map { position, pair in
            LogTransfer(
                amount: pair.1,
                from: address(2),
                position: position,
                standard: .erc1155,
                to: address(3),
                tokenId: pair.0
            )
        }
    }

    /// `(uint256[] ids, uint256[] values)` of `TransferBatch` data.
    static func decodeBatch(_ data: Data) -> ([BigUInt], [BigUInt]) {
        let words = EthereumABI.words(data).map { EthereumABI.decodeUInt256($0) }

        func array(at offset: BigUInt) -> [BigUInt] {
            guard let start = Int(exactly: offset / 32), start < words.count, let count = Int(exactly: words[start]),
                  start + count < words.count
            else {
                return []
            }

            return Array(words[(start + 1)...(start + count)])
        }

        guard words.count >= 2 else {
            return ([], [])
        }

        return (array(at: words[0]), array(at: words[1]))
    }

    private static func hexInt(_ string: String) -> Int? {
        Int(string.hasPrefix("0x") ? String(string.dropFirst(2)) : string, radix: 16)
    }
}

// MARK: - API

private enum EtherscanNFTAPI: TargetType {
    case transfers(
        action: String,
        address: String,
        apiKey: String,
        chainId: UInt64,
        endBlock: UInt64,
        offset: Int,
        page: Int,
        startBlock: UInt64
    )

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

    var task: Moya.Task {
        switch self {
        case let .transfers(action, address, apiKey, chainId, endBlock, offset, page, startBlock):
            .requestParameters(
                parameters: [
                    "action": action,
                    "address": address,
                    "apikey": apiKey,
                    "chainid": chainId,
                    "endblock": endBlock,
                    "module": "account",
                    "offset": offset,
                    "page": page,
                    "sort": "asc",
                    "startblock": startBlock
                ],
                encoding: URLEncoding.queryString
            )
        }
    }

    var validationType: ValidationType {
        .successCodes
    }
}

enum EtherscanNFTError: LocalizedError {
    case message(String)
    case rateLimited(String)
    case receiptUnavailable(String)
    case tooManyTransfersInBlock

    var errorDescription: String? {
        switch self {
        case let .message(message), let .rateLimited(message):
            String(localized: .etherscanError(message))
        case let .receiptUnavailable(hash):
            "No receipt for \(hash)"
        case .tooManyTransfersInBlock:
            "Too many NFT transfers in one block"
        }
    }
}

// MARK: - Responses

private struct EtherscanNFTResponse: Decodable {
    let result: [EtherscanNFTTransfer]

    enum CodingKeys: String, CodingKey {
        case message, result
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        if let result = try? container.decode([EtherscanNFTTransfer].self, forKey: .result) {
            self.result = result
            return
        }

        let message = try container.decodeIfPresent(String.self, forKey: .message) ?? "Unknown API error"
        let text = try container.decodeIfPresent(String.self, forKey: .result) ?? message

        if message == "No transactions found" {
            result = []
        } else if text.localizedCaseInsensitiveContains("rate limit") {
            throw EtherscanNFTError.rateLimited(text)
        } else {
            throw EtherscanNFTError.message(text)
        }
    }
}

/// One row of `tokennfttx` or `token1155tx`. Keys are converted from snake
/// case by the shared decoder; Etherscan's are already camel case.
struct EtherscanNFTTransfer: Decodable, Sendable {
    let blockHash: String?
    let blockNumber: String
    let contractAddress: String
    let from: String
    let hash: String
    let to: String
    let tokenID: String
    let tokenValue: String?
    let transactionIndex: String?
    var standard: NFTStandard = .erc721

    enum CodingKeys: String, CodingKey {
        case blockHash, blockNumber, contractAddress, from, hash, to, tokenID, tokenValue, transactionIndex
    }

    var identity: String {
        [hash, contractAddress, tokenID, from, to, tokenValue ?? "1"].joined(separator: "|").lowercased()
    }

    func with(standard: NFTStandard) -> Self {
        var copy = self
        copy.standard = standard
        return copy
    }

    func event(logIndex: Int, batchPosition: Int) -> NFTTransferEvent? {
        guard let blockNumber = UInt64(blockNumber) else {
            return nil
        }

        return NFTTransferEvent(
            amount: standard == .erc1155 ? BigUInt(tokenValue ?? "1") ?? 1 : 1,
            batchPosition: batchPosition,
            blockHash: blockHash,
            blockNumber: blockNumber,
            contract: contractAddress,
            from: from,
            logIndex: logIndex,
            source: NFTSourceId.etherscan.rawValue,
            standard: standard,
            to: to,
            tokenId: tokenID,
            transactionIndex: Int(transactionIndex ?? "") ?? 0,
            txHash: hash
        )
    }
}
