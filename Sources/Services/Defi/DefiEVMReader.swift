//
//  DefiEVMReader.swift
//  Reefr Wallet
//
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import BigInt
import Foundation
import WalletKit

/// A block identified by number and hash, so later reads can detect a reorg.
struct BlockRef: Codable, Equatable, Hashable, Sendable {
    let hash: String
    let number: UInt64
    let timestamp: Date
}

enum BlockTag: Equatable, Sendable {
    case finalized
    case latest
    case number(UInt64)

    var json: String {
        switch self {
        case .finalized: "finalized"
        case .latest: "latest"
        case let .number(number): "0x" + String(number, radix: 16)
        }
    }
}

struct EVMCall: Equatable, Sendable {
    let data: Data
    let target: EthereumAddress
}

struct EVMCallResult: Equatable, Sendable {
    let data: Data
    let isSuccess: Bool

    /// The message of a Solidity `Error(string)` revert, if this is one.
    var revertReason: String? {
        guard !isSuccess, data.count >= 4, data.prefix(4) == EVMCallResult.errorSelector else {
            return nil
        }

        return try? EthereumABI.decodeString(Data(data.dropFirst(4)))
    }

    static let errorSelector = EthereumABI.selector("Error(string)")
}

struct EVMLog: Equatable, Sendable {
    let blockHash: String
    let blockNumber: UInt64
    let data: Data
    let logIndex: UInt64
    let topics: [String]
    let transactionHash: String
}

/// Block-pinned EVM reads for DeFi plugins: block headers, batched calls and logs.
protocol DefiEVMReader: Sendable {
    /// The block for `tag`, or `nil` if the node doesn't know it (e.g. no `finalized` support).
    func block(_ tag: BlockTag) async throws -> BlockRef?

    /// Runs `calls` through Multicall3 `aggregate3` at `block`, each allowed to fail on its own.
    func call(_ calls: [EVMCall], at block: BlockRef) async throws -> [EVMCallResult]

    /// Logs of `address` in `from...to` matching `topics` (`nil` matches any).
    func logs(address: EthereumAddress, topics: [[String]?], from: UInt64, to: UInt64) async throws -> [EVMLog]

    /// The block range to start log queries with.
    var preferredLogRange: UInt64 { get }
}

extension DefiEVMReader {
    var preferredLogRange: UInt64 {
        100_000
    }
}

/// ``DefiEVMReader`` over JSON-RPC.
struct LiveDefiEVMReader: DefiEVMReader {
    static let callChunkSize = 100
    // swiftlint:disable:next force_try
    static let multicall3 = try! EthereumAddress(string: "0xcA11bde05977b3631167028862bE2a173976CA11")

    let client: EthereumRPCClient

    func block(_ tag: BlockTag) async throws -> BlockRef? {
        let params = try JSONSerialization.data(withJSONObject: [tag.json, false])
        let result: Data

        do {
            result = try await client.request(method: "eth_getBlockByNumber", params: params)
        } catch where tag == .finalized {
            return nil
        }

        guard let header = try JSONDecoder().decode(BlockHeader?.self, from: result) else {
            return nil
        }

        return try BlockRef(
            hash: header.hash.lowercased(),
            number: Self.quantity(header.number),
            timestamp: Date(timeIntervalSince1970: TimeInterval(Self.quantity(header.timestamp)))
        )
    }

    func call(_ calls: [EVMCall], at block: BlockRef) async throws -> [EVMCallResult] {
        var results: [EVMCallResult] = []

        for start in stride(from: 0, to: calls.count, by: Self.callChunkSize) {
            let chunk = Array(calls[start ..< min(start + Self.callChunkSize, calls.count)])
            let data = Multicall3.encodeAggregate3(chunk)
            let returned = try await ethCall(data: data, at: block)
            let decoded = try Multicall3.decodeAggregate3(returned)

            guard decoded.count == chunk.count else {
                throw BlockchainClientError.decodingFailed(reason: "aggregate3 returned \(decoded.count) of \(chunk.count) results")
            }

            results += decoded
        }

        return results
    }

    func logs(address: EthereumAddress, topics: [[String]?], from: UInt64, to: UInt64) async throws -> [EVMLog] {
        let filter: [String: Any] = [
            "address": address.string,
            "fromBlock": BlockTag.number(from).json,
            "toBlock": BlockTag.number(to).json,
            "topics": topics.map { $0.map { $0 as Any } ?? NSNull() }
        ]
        let params = try JSONSerialization.data(withJSONObject: [filter])
        let result = try await client.request(method: "eth_getLogs", params: params)

        return try JSONDecoder().decode([RawLog].self, from: result)
            .filter { $0.removed != true }
            .map { log in
                try EVMLog(
                    blockHash: log.blockHash.lowercased(),
                    blockNumber: Self.quantity(log.blockNumber),
                    data: Data(hexString: log.data),
                    logIndex: Self.quantity(log.logIndex),
                    topics: log.topics.map { $0.lowercased() },
                    transactionHash: log.transactionHash.lowercased()
                )
            }
    }

    // MARK: - Private

    private struct BlockHeader: Decodable {
        let hash: String
        let number: String
        let timestamp: String
    }

    private struct RawLog: Decodable {
        let blockHash: String
        let blockNumber: String
        let data: String
        let logIndex: String
        let removed: Bool?
        let topics: [String]
        let transactionHash: String
    }

    /// `eth_call` pinned by hash (EIP-1898), falling back to the number for
    /// nodes that reject it; callers recheck the head hash before using results.
    private func ethCall(data: Data, at block: BlockRef) async throws -> Data {
        let transaction = ["to": Self.multicall3.string, "data": data.hexEncoded]

        do {
            return try await ethCall(transaction, block: ["blockHash": block.hash])
        } catch {
            return try await ethCall(transaction, block: BlockTag.number(block.number).json)
        }
    }

    private func ethCall(_ transaction: [String: String], block: Any) async throws -> Data {
        let params = try JSONSerialization.data(withJSONObject: [transaction, block])
        let hex = try JSONDecoder().decode(String.self, from: await client.request(method: "eth_call", params: params))
        return try Data(hexString: hex)
    }

    private static func quantity(_ hex: String) throws -> UInt64 {
        guard let value = UInt64(hex.hasPrefix("0x") ? String(hex.dropFirst(2)) : hex, radix: 16) else {
            throw BlockchainClientError.decodingFailed(reason: "invalid quantity \(hex)")
        }

        return value
    }
}

// MARK: - Multicall3

/// `aggregate3((address,bool,bytes)[])` call data and return decoding.
enum Multicall3 {
    static let aggregate3 = EthereumABI.selector("aggregate3((address,bool,bytes)[])")

    static func encodeAggregate3(_ calls: [EVMCall]) -> Data {
        let tuples = calls.map { call in
            word(call.target) + word(1) + word(0x60) + word(BigUInt(call.data.count)) + padded(call.data)
        }

        var offsets = Data()
        var offset = 32 * calls.count

        for tuple in tuples {
            offsets += word(BigUInt(offset))
            offset += tuple.count
        }

        return aggregate3 + word(0x20) + word(BigUInt(calls.count)) + offsets + tuples.reduce(Data(), +)
    }

    static func decodeAggregate3(_ data: Data) throws -> [EVMCallResult] {
        let data = Data(data)
        let arrayStart = try int(data, at: 0)
        let count = try int(data, at: arrayStart)
        let base = arrayStart + 32

        return try (0 ..< count).map { index in
            let tupleStart = try base + int(data, at: base + 32 * index)
            let isSuccess = try int(data, at: tupleStart) != 0
            let bytesStart = try tupleStart + int(data, at: tupleStart + 32)
            let length = try int(data, at: bytesStart)

            guard bytesStart + 32 + length <= data.count else {
                throw BlockchainClientError.decodingFailed(reason: "aggregate3 return data out of bounds")
            }

            return EVMCallResult(
                data: data.subdata(in: bytesStart + 32 ..< bytesStart + 32 + length),
                isSuccess: isSuccess
            )
        }
    }

    // MARK: - Private

    private static func int(_ data: Data, at offset: Int) throws -> Int {
        guard offset >= 0, offset + 32 <= data.count,
              let value = Int(exactly: EthereumABI.decodeUInt256(data.subdata(in: offset ..< offset + 32)))
        else {
            throw BlockchainClientError.decodingFailed(reason: "aggregate3 return data out of bounds")
        }

        return value
    }

    private static func padded(_ data: Data) -> Data {
        data + Data(repeating: 0, count: (32 - data.count % 32) % 32)
    }

    private static func word(_ address: EthereumAddress) -> Data {
        EthereumABI.encodeCall(selector: Data(), parameters: [.address(address)])
    }

    private static func word(_ value: BigUInt) -> Data {
        EthereumABI.encodeCall(selector: Data(), parameters: [.uint256(value)])
    }
}
