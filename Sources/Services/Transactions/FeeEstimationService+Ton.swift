//
//  FeeEstimationService+Ton.swift
//  Reefr Wallet
//
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import BigInt
import Foundation
import WalletKit

extension FeeEstimationService {
    /// Estimates the actual message, including the wallet's `StateInit` for a first send.
    func estimateTonFees(token: Token, amount: BigUInt, recipient: String, account: Account) async throws -> Fees {
        guard token.isNativeToken else {
            throw ReefrError.notSupported
        }

        let builder = try clientProvider.makeTransactionBuilder(
            blockchain: account.blockchain,
            rpcURL: account.rpcURLOverride,
            publicKey: account.publicKey
        )

        let unsigned = try await builder.buildTransfer(
            sender: account.address,
            recipient: recipient,
            amount: amount,
            token: nil,
            options: []
        )

        let transaction = try JSONDecoder().decode(TonUnsignedTransaction.self, from: unsigned)
        let client = try clientProvider.makeClient(blockchain: account.blockchain, rpcURL: account.rpcURLOverride)

        guard let client = client as? TonClient else {
            throw ReefrError.invalidData
        }

        let fee = try await client.estimateFee(transaction)
        return Fees(nativeFeeReserve: String(fee.total))
    }
}
