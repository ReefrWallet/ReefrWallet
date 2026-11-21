//
//  NodeLogNFTSource.swift
//  Reefr Wallet
//
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import BigInt
import Foundation
import WalletKit

/// Replays an EVM account's ERC-721/1155 transfers from its own node's
/// `eth_getLogs`. Used first for accounts with an RPC override, whose chain
/// public indexers may not see (a fork, a devnet). See ADR-072.
struct NodeLogNFTSource: NFTSource {
    static let blockChunk: UInt64 = 100_000

    private static let erc1155Topics = [
        "0xc3d58168c5ae7397731d063d5bbf3d657854427343f4c083240f7aacaa2d0f62",
        "0x4a39dc06d4c0dbc64b70af90fd698a233a518aa5d07e595d983b8c0526c8f7fb"
    ]
    private static let transferTopic = "0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef"

    private let clientProvider: BlockchainClientProvider

    let id = NFTSourceId.node

    init(clientProvider: BlockchainClientProvider = BlockchainClientProvider()) {
        self.clientProvider = clientProvider
    }

    func supports(_ blockchain: Blockchain) -> Bool {
        if case .evm = blockchain {
            return true
        }

        return false
    }

    func scan(account: Account, request: NFTScanRequest) async throws -> NFTScanResult {
        let client = try clientProvider.ethereumClient(for: account)
        let head = try await blockNumber(client)
        let owner = "0x" + String(repeating: "0", count: 24) + account.address.lowercased().dropFirst(2)
        var events: [String: NFTTransferEvent] = [:]
        var start = request.overlapStart

        while start <= head {
            let end = min(head, start + Self.blockChunk - 1)

            for topics in Self.filters(owner: owner) {
                for event in try await logs(client, from: start, to: end, topics: topics) {
                    events[event.key(accountKey: "")] = event
                }
            }

            start = end + 1
        }

        return .ledger(NFTLedgerScan(
            events: Array(events.values),
            fromBlock: request.overlapStart,
            metadata: [:],
            scannedBlock: max(request.scannedBlock ?? 0, head)
        ))
    }

    /// Owner as sender or recipient: ERC-721 `Transfer` topics 1/2,
    /// ERC-1155 `TransferSingle`/`TransferBatch` topics 2/3.
    static func filters(owner: String) -> [JSONValue] {
        let transfer = JSONValue.array([.string(transferTopic)])
        let erc1155 = JSONValue.array(erc1155Topics.map(JSONValue.string))
        let owner = JSONValue.array([.string(owner)])

        return [
            .array([transfer, owner]),
            .array([transfer, .null, owner]),
            .array([erc1155, .null, owner]),
            .array([erc1155, .null, .null, owner])
        ]
    }

    private func blockNumber(_ client: EthereumRPCClient) async throws -> UInt64 {
        let value = try JSONValue(data: await client.request(method: "eth_blockNumber", params: Data("[]".utf8)))

        guard let head = value.stringValue.flatMap({ UInt64($0.dropFirst(2), radix: 16) }) else {
            throw BlockchainClientError.invalidResponse(reason: "eth_blockNumber returned no block")
        }

        return head
    }

    private func logs(
        _ client: EthereumRPCClient,
        from: UInt64,
        to: UInt64,
        topics: JSONValue
    ) async throws -> [NFTTransferEvent] {
        let filter = JSONValue.object([
            "fromBlock": .string("0x" + String(from, radix: 16)),
            "toBlock": .string("0x" + String(to, radix: 16)),
            "topics": topics
        ])
        let response = try JSONValue(
            data: await client.request(method: "eth_getLogs", params: JSONValue.array([filter]).encoded())
        )

        return (response.arrayValue ?? []).flatMap(Self.events)
    }

    static func events(_ log: JSONValue) -> [NFTTransferEvent] {
        func hex(_ key: String) -> UInt64? {
            log[key]?.stringValue.flatMap { UInt64($0.dropFirst(2), radix: 16) }
        }

        guard let topics = log["topics"]?.arrayValue?.compactMap(\.stringValue), topics.count == 4,
              let contract = log["address"]?.stringValue,
              let hash = log["transactionHash"]?.stringValue,
              let block = hex("blockNumber"),
              let logIndex = hex("logIndex"),
              log["removed"]?.boolValue != true
        else {
            return []
        }

        let data = (try? Data(hexString: log["data"]?.stringValue ?? "0x")) ?? Data()

        return EtherscanNFTSource.transfers(topics: topics, data: data).map { transfer in
            NFTTransferEvent(
                amount: transfer.amount,
                batchPosition: transfer.position,
                blockHash: log["blockHash"]?.stringValue,
                blockNumber: block,
                contract: contract,
                from: transfer.from,
                logIndex: Int(logIndex),
                source: NFTSourceId.node.rawValue,
                standard: transfer.standard,
                to: transfer.to,
                tokenId: transfer.tokenId.description,
                transactionIndex: Int(hex("transactionIndex") ?? 0),
                txHash: hash
            )
        }
    }
}
