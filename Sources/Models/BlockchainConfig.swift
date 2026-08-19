//
//  Blockchain.swift
//  Reefr Wallet
//
//  Created by Andrey Yurkevich on 31.01.26.
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import Foundation
import SwiftData
import WalletKit

@Model
final class BlockchainConfig {
    var displayName: String
    var endpointURL: URL
    var isTestnet: Bool
    var nativeToken: Token
    var networkName: String
    /// `nil` for blockchain networks added manually
    var presetId: String?
    var serializedBlockchain: String
    var systemImage: String

    @Relationship(deleteRule: .cascade, inverse: \Token.blockchain)
    var tokens: [Token]

    init(
        blockchain: Blockchain,
        displayName: String,
        endpointURL: URL,
        isTestnet: Bool,
        isUserAdded: Bool,
        nativeToken: Token,
        networkName: String,
        presetId: String? = nil,
        systemImage: String
    ) throws {
        self.displayName = displayName
        self.endpointURL = endpointURL
        self.isTestnet = isTestnet
        self.nativeToken = nativeToken
        self.networkName = networkName
        self.presetId = presetId
        self.serializedBlockchain = try blockchain.asJSONString()
        self.systemImage = systemImage

        tokens = []
    }
}

extension BlockchainConfig {
    var blockchain: Blockchain {
        // swiftlint:disable:next force_try
        get { try! serializedBlockchain.decoded() }
        // swiftlint:disable:next force_try
        set { serializedBlockchain = try! newValue.asJSONString() }
    }

    func getToken(address: String) throws -> Token? {
        guard let token = tokens.first(where: { $0.address == address }) else {
            return nil
        }

        return token
    }
}

extension BlockchainConfig: Decodable {
    convenience init(from decoder: Decoder) throws { // swiftlint:disable:this function_body_length
        let container = try decoder.container(keyedBy: CodingKeys.self)

        var blockchain = try container.decodeIfPresent(Blockchain.self, forKey: .blockchain)

        if blockchain == nil {
            let kind = try container.decode(String.self, forKey: .kind)

            let chainId = try container.decodeIfPresent(String.self, forKey: .chainId)

            switch kind {
            case "sui":
                blockchain = .sui(.ed25519)
            case "evm":
                guard let chainId else {
                    throw DecodingError.dataCorruptedError(
                        forKey: .chainId,
                        in: container,
                        debugDescription: "No chain id"
                    )
                }

                let parsedChainId = chainId.hasPrefix("0x")
                    ? UInt64(chainId.dropFirst(2), radix: 16)
                    : UInt64(chainId)

                guard let chainId = parsedChainId else {
                    throw DecodingError.dataCorruptedError(
                        forKey: .chainId,
                        in: container,
                        debugDescription: "Can't parse chain id"
                    )
                }

                blockchain = .ethereum(chainId)
            default:
                throw DecodingError.dataCorruptedError(
                    forKey: .kind,
                    in: container,
                    debugDescription: "Unsupported blockchain kind: \(kind)"
                )
            }
        }

        guard let blockchain else {
            throw DecodingError.dataCorruptedError(
                forKey: .blockchain,
                in: container,
                debugDescription: "No blockchain"
            )
        }

        let displayName = try container.decode(String.self, forKey: .displayName)
        let endpointURL = try container.decode(URL.self, forKey: .endpointURL)
        let isTestnet = try container.decode(Bool.self, forKey: .isTestnet)
        let nativeToken = try container.decode(Token.self, forKey: .nativeToken)
        let networkName = try container.decode(String.self, forKey: .networkName)
        let presetId = try container.decode(String.self, forKey: .presetId)
        let systemImage = try container.decode(String.self, forKey: .systemImage)

        try self.init(
            blockchain: blockchain,
            displayName: displayName,
            endpointURL: endpointURL,
            isTestnet: isTestnet,
            isUserAdded: false,
            nativeToken: nativeToken,
            networkName: networkName,
            presetId: presetId,
            systemImage: systemImage
        )

        self.tokens = [nativeToken]
    }

    private enum CodingKeys: String, CodingKey {
        case blockchain
        case chainId
        case endpointURL = "rpcUrl"
        case displayName = "blockchainName"
        case isTestnet
        case kind
        case nativeToken
        case networkName
        case presetId
        case systemImage
    }
}
