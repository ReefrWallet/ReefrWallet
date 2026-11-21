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
    /// Estimates the actual message, including the wallet's `StateInit` for a first send. A Jetton transfer is
    /// emulated through its whole trace: the Gram that must be held to send it is the reserve, and what it costs once
    /// the excess is refunded is the net cost.
    func estimateTonFees(token: Token, amount: BigUInt, recipient: String, account: Account) async throws -> Fees {
        let builder = try clientProvider.makeTransactionBuilder(
            blockchain: account.blockchain,
            rpcURL: account.rpcURLOverride,
            publicKey: account.publicKey
        )

        let tokenId = token.isNativeToken ? nil : token.address

        func build(_ options: [BlockchainTransactionBuilderOptions]) async throws -> TonUnsignedTransaction {
            let unsigned = try await builder.buildTransfer(
                sender: account.address,
                recipient: recipient,
                amount: amount,
                token: tokenId,
                // The requirement is what the emulation is about to find out, so the fixed one must not pre-empt it.
                options: [.tonRequiredGram(0)] + options
            )

            return try JSONDecoder().decode(TonUnsignedTransaction.self, from: unsigned)
        }

        let client = try clientProvider.makeClient(blockchain: account.blockchain, rpcURL: account.rpcURLOverride)

        guard let client = client as? TonClient else {
            throw ReefrError.invalidData
        }

        guard tokenId != nil else {
            return Fees(nativeFeeReserve: String(try await client.estimateFee(try await build([])).total))
        }

        let fees = try await Self.jettonFees(
            build: { try await build([.tonJettonAttachment($0)]) },
            quote: { try await client.quote($0) }
        )

        // Shown beside the fee rows and keeps Send disabled; the builder checks again when the transfer is built.
        if let balance = try? await client.getNativeBalance(client.makeAddress(account.address)) {
            try Self.ensureGram(for: fees, balance: balance)
        }

        return fees
    }

    /// Throws ``TonSendError/insufficientGram(required:available:)`` when `balance` is below the quoted requirement.
    static func ensureGram(for fees: Fees, balance: BigUInt) throws {
        guard let required = fees.nativeFeeReserve.flatMap({ BigUInt($0) }), balance < required else {
            return
        }

        throw TonSendError.insufficientGram(required: required, available: balance)
    }

    /// Tries the attachments in turn and keeps the first whose emulation credits the recipient, with the Gram that
    /// takes and what is left once the excess returns. An inconclusive emulation (an incomplete trace) keeps the
    /// attachment it was tried with. Without emulation the builder's fixed budget applies, with no net cost shown.
    static func jettonFees(
        steps: [BigUInt] = TonTransactionBuilder.jettonAttachmentSteps,
        build: (BigUInt) async throws -> TonUnsignedTransaction,
        quote: (TonUnsignedTransaction) async throws -> TonSendQuote
    ) async throws -> Fees {
        var refused = false

        for attachment in steps {
            // Builder errors (a key that isn't the sender's, too few tokens) belong to the caller, not to the fallback.
            let transaction = try await build(attachment)

            do {
                let result = try await quote(transaction)

                if result.expectedToFail {
                    refused = true
                    continue
                }

                return Fees(
                    nativeFeeReserve: String(result.upfront),
                    tonAttachment: String(attachment),
                    tonNetCost: result.net.map { String($0) }
                )
            } catch {
                // A smaller attachment was already refused, so the fixed budget would only bring it back.
                guard !refused else {
                    throw TonSendError.attachmentUndetermined
                }

                printError("TON emulation unavailable, using the fixed budget: \(error)")
                return Fees(
                    estimateWarning: String(localized: .transferEstimateFailed(error.localizedDescription)),
                    nativeFeeReserve: String(TonTransactionBuilder.defaultJettonAttachment
                        + TonTransactionBuilder.jettonFeeReserve)
                )
            }
        }

        throw TonSendError.wouldFail
    }
}
