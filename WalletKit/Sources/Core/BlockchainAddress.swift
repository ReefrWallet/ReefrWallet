//
//  BlockchainAddress.swift
//  WalletKit
//
//  Created by Andrey Yurkevich on 16/08/2026.
//

import Foundation

public protocol BlockchainAddress: Equatable {
    var string: String { get }
    var rawBytes: Data { get }

    init(string: String) throws
    init(rawBytes: Data) throws
}

public protocol Signer {
    associatedtype Address: BlockchainAddress

    var blockchain: Blockchain { get }

    func address(for account: Account) throws -> Address
    func sign(transaction: Data, account: Account) async throws -> Data
}

public protocol HardwareSigner {
    associatedtype UnsignedTransaction
    associatedtype SignedTransaction

    func sign(
        _ transaction: UnsignedTransaction,
        account: Account,
        device: HardwareDevice
    ) async throws -> SignedTransaction
}
