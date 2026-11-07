//
//  ReceiveAddress.swift
//  Reefr Wallet
//
//  Created by Andrey Yurkevich on 07.11.26.
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import BigInt
import Foundation
import SwiftData

// MARK: - ReceiveAddress

/// One external address of a Cardano account. `isUsed` and `lovelace` are `nil` until a
/// refresh has checked the address.
struct ReceiveAddress: Equatable, Hashable, Identifiable, Sendable {
    let address: String
    let index: UInt32
    let isUsed: Bool?
    let lovelace: BigUInt?

    var id: UInt32 { index }
}

// MARK: - ReceiveAddressModel

@Model
final class ReceiveAddressModel {
    var address: String
    var index: Int
    var isUsed: Bool?
    var serializedLovelace: Data?

    @Relationship(deleteRule: .noAction)
    var account: AccountModel

    init(account: AccountModel, address: String, index: Int, isUsed: Bool? = nil, lovelace: BigUInt? = nil) {
        self.account = account
        self.address = address
        self.index = index
        self.isUsed = isUsed
        serializedLovelace = lovelace?.serialize()
    }
}

extension ReceiveAddress {
    init(model: ReceiveAddressModel) {
        address = model.address
        index = UInt32(truncatingIfNeeded: model.index)
        isUsed = model.isUsed
        lovelace = model.serializedLovelace.map { BigUInt($0) }
    }
}
