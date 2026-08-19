//
//  SavedAddress.swift
//  Reefr Wallet
//
//  Created by Andrey Yurkevich on 22.02.26.
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import SwiftData
import WalletKit

@Model
final class SavedAddress {
    var address: String
    var serializedBlockchain: String
    var memo: String

    init(address: String, blockchain: Blockchain, memo: String) throws {
        self.address = address
        self.memo = memo
        self.serializedBlockchain = try blockchain.asJSONString()
    }
}

extension SavedAddress {
    var blockchain: Blockchain {
        // swiftlint:disable force_try
        get {
            try! serializedBlockchain.decoded()
        }
        set {
            serializedBlockchain = try! newValue.asJSONString()
        }
        // swiftlint:enable force_try
    }
}
