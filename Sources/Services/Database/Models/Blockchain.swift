//
//  Blockchain.swift
//  Reefr Wallet
//
//  Created by Andrey Yurkevich on 28.12.25.
//  Copyright © 2025 Reefr Wallet. All rights reserved.
//

import Foundation
import SwiftData
import WalletKit

// MARK: - BlockchainModel

@Model
final class BlockchainModel {
    var serialized: String

    @Relationship(deleteRule: .cascade)
    var nativeToken: TokenModel

    @Relationship(deleteRule: .cascade)
    var tokens: [TokenModel]

    init(blockchain: Blockchain) throws {
        let nativeToken = TokenModel(from: blockchain.nativeToken)
        self.serialized = try blockchain.asJSONString()
        self.nativeToken = nativeToken
        self.tokens = [nativeToken]
    }

    var blockchain: Blockchain {
        guard let blockchain: Blockchain = try? serialized.decoded() else {
            preconditionFailure("Cannot decode blockchain")
        }

        return blockchain
    }
}
