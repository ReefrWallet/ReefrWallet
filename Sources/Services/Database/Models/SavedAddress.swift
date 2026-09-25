//
//  SavedAddressModel.swift
//  Reefr Wallet
//
//  Created by Andrey Yurkevich on 22.02.26.
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import SwiftData
import WalletKit

@Model
final class SavedAddressModel {
    var address: String
    var memo: String
    var serializedBlockchain: String

    init(address: String, blockchain: Blockchain, memo: String) throws {
        self.address = address
        self.serializedBlockchain = try blockchain.asJSONString()
        self.memo = memo
    }

    var blockchain: Blockchain {
        guard let blockchain: Blockchain = try? serializedBlockchain.decoded() else {
            preconditionFailure()
        }

        return blockchain
    }
}
