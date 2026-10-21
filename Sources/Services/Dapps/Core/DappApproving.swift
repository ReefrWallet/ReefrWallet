//
//  DappApproving.swift
//  Reefr Wallet
//
//  Created by Andrey Yurkevich on 25.09.26.
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import Foundation
import WalletKit

/// One thing a dapp is asking the wallet to approve — connecting, signing
/// a message, or sending a transaction. Chain-agnostic; the interesting
/// per-chain detail lives in the associated preview value.
enum DappApprovalRequest: Sendable {
    case connect(origin: String, namespace: DappNamespace, account: Account)
    case signMessage(origin: String, namespace: DappNamespace, account: Account, preview: DappMessagePreview)
    case sendTransaction(origin: String, namespace: DappNamespace, account: Account, preview: DappTransactionPreview)
}

/// A message a dapp asked the user to sign, per chain — mirrors
/// ADR-018's per-chain presenter pattern for browser approval sheets.
enum DappMessagePreview: Sendable {
    /// The full AIP-62 message the wallet assembled and will sign.
    case aptosMessage(String)
    case ethereumPersonal(Data)
    case ethereumTypedData(EthereumTypedDataSummary)
    case solanaMessage(Data)
    case suiPersonal(Data)
    /// A TronWeb `signMessageV2` message's raw bytes.
    case tronMessage(Data)

    // Later: .cardanoCIP8, .bitcoinBIP322.
}

/// A transaction a dapp asked the user to send, per chain.
enum DappTransactionPreview: Sendable {
    case aptos(AptosTransactionPreview)
    case ethereum(EthereumCallPreview, Fees)
    case solana(SolanaTransactionPreview)
    case sui(SuiTransactionPreview)
    case tron(TronTransactionPreview)

    // Later: other chains' call/transfer previews.
}

/// A dapp-supplied Solana transaction (`solana:signTransaction`/
/// `solana:signAndSendTransaction`), for the approval detail view.
/// `transaction` is always fully parsed and validated before this is ever
/// constructed — ``SolanaDappProvider`` rejects a transaction outright
/// (before any approval prompt) if it fails to parse or the authorized
/// account doesn't occupy one of its required-signer slots.
struct AptosTransactionPreview: Sendable {
    let rawBytes: Data
    let transaction: AptosRawTransaction
}

struct SolanaTransactionPreview: Sendable {
    let feePayer: SolanaAddress
    let programIds: [SolanaAddress]
    let rawBytes: Data
    let transaction: SolanaWireTransaction
}

/// A dapp-supplied Sui transaction (`sui:signTransaction`/
/// `sui:signAndExecuteTransaction`), for the approval detail view.
/// `summary` is always fully validated before this is ever constructed
/// — ``SuiDappProvider`` rejects a transaction outright (before any
/// approval prompt) if it can't decode `rawBytes` or if the decoded
/// sender doesn't match the authorized account, so there's no
/// "undecoded fallback" state here the way ``EthereumCallPreview``
/// tolerates raw hex for undecoded contract call `data`.
struct SuiTransactionPreview: Sendable {
    let rawBytes: Data
    let summary: SuiTransactionDataSummary
}

/// A dapp-supplied Tron transaction (TronWeb `trx.sign`), for the
/// approval detail view. `transaction` is decoded from the exact bytes
/// that get signed — ``TronDappProvider`` rejects anything it can't fully
/// decode, or whose owner isn't the authorized account, before any prompt.
struct TronTransactionPreview: Sendable {
    /// The called TRC-20 token's symbol and decimals, for display.
    struct Token: Sendable {
        let decimals: UInt8
        let symbol: String
    }

    let transaction: TronRawTransaction
    /// `nil` if not a TRC-20 call or the lookup failed (base units shown).
    var token: Token?
    /// `nil` if the estimate failed (only the fee limit shown).
    var fee: TronFeeEstimate?

    /// TRC-20 `transfer`, `approve`, `transferFrom` — the calls whose
    /// token the preview looks up.
    static let knownTokenSelectors: Set<Data> = [
        Data([0xa9, 0x05, 0x9c, 0xbb]), Data([0x09, 0x5e, 0xa7, 0xb3]), Data([0x23, 0xb8, 0x72, 0xdd])
    ]
}

/// The `to`/`value`/`data` fields of an Ethereum `eth_sendTransaction`
/// call, for the transaction-approval detail view. `gasLimit` is the one
/// that gets signed; the accompanying ``Fees`` already include any
/// dapp-supplied fee caps.
struct EthereumCallPreview: Sendable {
    let to: String?
    let value: BigUInt
    let data: Data
    let gasLimit: BigUInt
    /// The dapp supplied `gas`/`gasPrice`/`maxFeePerGas`/`maxPriorityFeePerGas`.
    let hasDappFeeOverrides: Bool
}

/// The `primaryType`/domain/message/types of an EIP-712 typed-data
/// payload, for the typed-data approval detail view. `types` is part of
/// the signed payload (it determines each field's encoding), so it's
/// included alongside domain/message rather than left out of the
/// preview.
struct EthereumTypedDataSummary: Sendable {
    let primaryType: String
    let domainJSON: String
    let messageJSON: String
    let typesJSON: String
}

/// What the user decided about a ``DappApprovalRequest``.
enum DappApprovalResult: Sendable {
    case approved
    case approvedWithFees(Fees)
    case rejected
}

/// Presents a ``DappApprovalRequest`` to the user and reports back their
/// decision. `DappApprover` (`Browser/DappApprover.swift`) is the
/// `@MainActor @Observable` UI-facing implementation; a stub in tests
/// answers immediately.
protocol DappApproving: Sendable {
    func approve(_ request: DappApprovalRequest) async -> DappApprovalResult

    /// Called once the request with `requestId` (``DappRequestScope/id``)
    /// has been fully handled.
    func didFinishRequest(_ requestId: UUID) async

    /// Tells the user an approved request failed (e.g. the hardware wallet
    /// was unavailable) — dapps often swallow the rejected promise.
    func reportFailure(_ message: String) async
}

extension DappApproving {
    func didFinishRequest(_ requestId: UUID) async {}

    func reportFailure(_ message: String) async {}
}

/// Identifies the dapp request being handled, so an approver can tell when
/// the request it approved has finished.
enum DappRequestScope {
    @TaskLocal static var id: UUID?

    /// Runs `operation` as the request `requestId`, then reports it finished
    /// to `approving`.
    static func run<T, E: Error>(
        _ requestId: UUID = UUID(),
        approving: any DappApproving,
        _ operation: () async throws(E) -> T
    ) async throws(E) -> T {
        let result: Result<T, E> = await $id.withValue(requestId) {
            do throws(E) {
                return .success(try await operation())
            } catch {
                return .failure(error)
            }
        }

        await approving.didFinishRequest(requestId)
        return try result.get()
    }
}
