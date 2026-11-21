//
//  BlockscoutNFTSource.swift
//  Reefr Wallet
//
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import Alamofire
import BigInt
import Foundation
import Moya
import WalletKit

/// Replays an EVM account's ERC-721/1155 transfers from Blockscout's
/// newest-first token-transfer list, down to the scan's overlap start.
struct BlockscoutNFTSource: NFTSource {
    private let apiBaseURLs: [UInt64: URL]
    private let sessionConfiguration: URLSessionConfiguration

    let id = NFTSourceId.blockscout

    init(
        apiBaseURLs: [UInt64: URL] = BlockscoutTransactionHistorySource.defaultAPIBaseURLs,
        sessionConfiguration: URLSessionConfiguration = .default
    ) {
        self.apiBaseURLs = apiBaseURLs
        self.sessionConfiguration = sessionConfiguration
    }

    func supports(_ blockchain: Blockchain) -> Bool {
        apiBaseURL(for: blockchain) != nil
    }

    func scan(account: Account, request: NFTScanRequest) async throws -> NFTScanResult {
        guard let baseURL = apiBaseURL(for: account.blockchain) else {
            throw URLError(.unsupportedURL)
        }

        let provider: MoyaProvider<BlockscoutNFTAPI> = RateGateRegistry.shared.makeProvider(
            origin: BlockscoutTransactionHistorySource.origin(of: baseURL),
            provider: .blockscout,
            configuration: sessionConfiguration
        )

        var items: [BlockscoutNFTTransfer] = []
        var pagination: BlockscoutPageParameters?

        repeat {
            let page: BlockscoutListResponse<BlockscoutNFTTransfer> = try await provider.request(
                .transfers(address: account.address, baseURL: baseURL, pagination: pagination)
            )

            items += page.items
            pagination = page.nextPageParams

            if let oldest = page.items.compactMap(\.blockNumber).min(), oldest < request.overlapStart {
                break
            }
        } while pagination != nil

        let window = items.filter { ($0.blockNumber ?? 0) >= request.overlapStart }
        let events = Self.events(window)

        return .ledger(NFTLedgerScan(
            events: events,
            fromBlock: request.overlapStart,
            metadata: Self.metadata(window),
            scannedBlock: max(request.scannedBlock ?? 0, events.map(\.blockNumber).max() ?? 0)
        ))
    }

    /// Ledger events of `items`. Batch items either arrive as one entry with an
    /// array `total` (position = index) or as entries sharing a log index
    /// (position = rank by token id).
    static func events(_ items: [BlockscoutNFTTransfer]) -> [NFTTransferEvent] {
        let grouped = Dictionary(grouping: items) { "\($0.transactionHash)|\($0.logIndex)" }

        return grouped.values.flatMap { group -> [NFTTransferEvent] in
            let totals = group
                .flatMap { transfer in transfer.totals.map { (transfer: transfer, total: $0) } }
                .sorted { ($0.total.position, $0.total.tokenId) < ($1.total.position, $1.total.tokenId) }

            return totals.enumerated().compactMap { position, pair -> NFTTransferEvent? in
                let transfer = pair.transfer
                guard let standard = transfer.standard, let blockNumber = transfer.blockNumber else {
                    return nil
                }

                return NFTTransferEvent(
                    amount: standard == .erc1155 ? BigUInt(pair.total.value ?? "1") ?? 1 : 1,
                    batchPosition: position,
                    blockHash: transfer.blockHash,
                    blockNumber: blockNumber,
                    contract: transfer.token.addressHash ?? transfer.token.address ?? "",
                    from: transfer.from?.hash ?? "0x0000000000000000000000000000000000000000",
                    logIndex: transfer.logIndex,
                    source: NFTSourceId.blockscout.rawValue,
                    standard: standard,
                    to: transfer.to?.hash ?? "0x0000000000000000000000000000000000000000",
                    tokenId: pair.total.tokenId,
                    transactionIndex: 0,
                    txHash: transfer.transactionHash
                )
            }
        }
        .filter { !$0.contract.isEmpty }
    }

    static func metadata(_ items: [BlockscoutNFTTransfer]) -> [String: OwnedNFT] {
        var result: [String: OwnedNFT] = [:]

        for item in items {
            guard let standard = item.standard, let contract = item.token.addressHash ?? item.token.address else {
                continue
            }

            for total in item.totals {
                let reference = NFTReference(
                    collection: contract.lowercased(),
                    isTransferable: true,
                    standard: standard,
                    tokenId: total.tokenId
                )

                let instance = total.tokenInstance

                result[NFTLedger.assetKey(reference)] = OwnedNFT(
                    collectionName: item.token.name,
                    imageURI: instance?.imageUrl ?? instance?.metadata?.image,
                    name: instance?.metadata?.name,
                    reference: reference
                )
            }
        }

        return result
    }

    private func apiBaseURL(for blockchain: Blockchain) -> URL? {
        guard case let .evm(chain) = blockchain else {
            return nil
        }

        return apiBaseURLs[chain.chainId]
    }
}

// MARK: - API

private enum BlockscoutNFTAPI: TargetType {
    case transfers(address: String, baseURL: URL, pagination: BlockscoutPageParameters?)

    var baseURL: URL {
        switch self {
        case let .transfers(_, baseURL, _): baseURL
        }
    }

    var headers: [String: String]? {
        ["Accept": "application/json"]
    }

    var method: Moya.Method {
        .get
    }

    var path: String {
        switch self {
        case let .transfers(address, _, _): "addresses/\(address)/token-transfers"
        }
    }

    var task: Moya.Task {
        switch self {
        case let .transfers(_, _, pagination):
            .requestParameters(
                parameters: (pagination?.parameters ?? [:]).merging(["type": "ERC-721,ERC-1155"]) { $1 },
                encoding: URLEncoding.queryString
            )
        }
    }

    var validationType: ValidationType {
        .successCodes
    }
}

// MARK: - Responses

struct BlockscoutNFTTransfer: Decodable {
    struct Address: Decodable {
        let hash: String
    }

    struct Instance: Decodable {
        struct Metadata: Decodable {
            let image: String?
            let name: String?
        }

        let imageUrl: String?
        let metadata: Metadata?
    }

    struct Token: Decodable {
        let address: String?
        let addressHash: String?
        let name: String?
        let type: String?
    }

    struct Total: Decodable {
        var position = 0
        let tokenId: String
        let tokenInstance: Instance?
        let value: String?

        enum CodingKeys: String, CodingKey {
            case tokenId, tokenInstance, value
        }
    }

    let blockHash: String?
    let blockNumber: UInt64?
    let from: Address?
    let logIndex: Int
    let to: Address?
    let token: Token
    let totals: [Total]
    let transactionHash: String

    var standard: NFTStandard? {
        switch token.type {
        case "ERC-721": .erc721
        case "ERC-1155": .erc1155
        default: nil
        }
    }

    enum CodingKeys: String, CodingKey {
        case blockHash, blockNumber, from, logIndex, to, token, total, transactionHash
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        blockHash = try container.decodeIfPresent(String.self, forKey: .blockHash)
        blockNumber = try container.decodeIfPresent(UInt64.self, forKey: .blockNumber)
        from = try container.decodeIfPresent(Address.self, forKey: .from)
        logIndex = try container.decode(Int.self, forKey: .logIndex)
        to = try container.decodeIfPresent(Address.self, forKey: .to)
        token = try container.decode(Token.self, forKey: .token)
        transactionHash = try container.decode(String.self, forKey: .transactionHash)

        if let batch = try? container.decode([Total].self, forKey: .total) {
            totals = batch.enumerated().map { index, total in
                var total = total
                total.position = index
                return total
            }
        } else {
            totals = try container.decodeIfPresent(Total.self, forKey: .total).map { [$0] } ?? []
        }
    }
}
