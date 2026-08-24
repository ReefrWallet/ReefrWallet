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

    @Relationship
    var blockchain: BlockchainModel

    init(address: String, blockchain: BlockchainModel, memo: String) throws {
        self.address = address
        self.blockchain = blockchain
        self.memo = memo
    }
}
