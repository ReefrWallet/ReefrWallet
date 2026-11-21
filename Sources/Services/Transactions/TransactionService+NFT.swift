//
//  TransactionService+NFT.swift
//  Reefr Wallet
//
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import BigInt
import WalletKit

extension TransactionService {
    /// Builds unsigned transaction bytes sending `quantity` of `nft` from
    /// `account` to `recipient`. Cardano requires `cardanoRecipientLovelace`.
    func makeNFTTransaction(
        nft: NFTReference,
        quantity: BigUInt,
        cardanoRecipientLovelace: String? = nil,
        recipient: String,
        account: Account,
        fees: Fees? = nil
    ) async throws -> Data {
        var options = try fees.map { try buildOptions($0, blockchain: account.blockchain) } ?? []

        if case .cardano = account.blockchain {
            guard let cardanoRecipientLovelace, let lovelace = UInt64(cardanoRecipientLovelace) else {
                throw ReefrError.invalidData
            }

            options.append(.cardanoRecipientLovelace(lovelace))
        }

        let builder = try clientProvider.makeTransactionBuilder(
            blockchain: account.blockchain,
            rpcURL: account.rpcURLOverride
        )

        guard let nftBuilder = builder as? any NFTTransactionBuilding else {
            throw BlockchainTransactionBuilderError.unsupportedNFT(reason: "\(account.blockchain) has no NFT transfers")
        }

        return try await nftBuilder.buildNFTTransfer(
            sender: account.address,
            recipient: recipient,
            nft: nft,
            quantity: quantity,
            options: options
        )
    }
}
