//
//  TronDappProvider.swift
//  Reefr Wallet
//
//  Created by Andrey Yurkevich on 13.10.26.
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import WalletKit

/// The TronLink-compatible provider behind `providers/tron.js`
/// (`window.tronLink`/`window.tronWeb`/`window.tron`). The page's TronWeb
/// builds transactions; this side only connects, signs, and relays
/// TronWeb's node requests (see ADR-030).
///
/// Transactions are decoded from `raw_data_hex` (the bytes actually
/// signed) by ``TronRawTransaction`` before any prompt. Trezor accounts
/// additionally require that the device's own rebuild of those bytes
/// (`tronRawData`) matches exactly, and can't sign messages.
struct TronDappProvider: DappProvider {
    static let namespace = DappNamespace.tron

    let clientProvider: BlockchainClientProvider
    private let transactionService: TransactionService

    /// Every dependency defaults to the global DI container; tests pass
    /// their own isolated instances.
    init(
        clientProvider: BlockchainClientProvider? = nil,
        transactionService: TransactionService? = nil
    ) {
        self.clientProvider = clientProvider ?? DI.injectOrFail(BlockchainClientProvider.self)
        self.transactionService = transactionService ?? DI.injectOrFail(TransactionService.self)
    }

    func handle(method: String, params: JSONValue, context: DappRequestContext) async throws(DappError) -> JSONValue {
        switch method {
        case "connect":
            return try await connect(params: params, context: context)
        case "disconnect":
            await context.session.revokePermission(.tron)
            return .null
        case "network":
            return Self.networkPayload(for: await context.session.selectedAccount(.tron))
        case "nodeRequest":
            return try await nodeRequest(params: params, context: context)
        case "signMessage":
            return try await signMessage(params: params, context: context)
        case "signTransaction":
            return try await signTransaction(params: params, context: context)
        default:
            throw .unsupportedMethod
        }
    }

    /// One `"change"` event with the connected account (or `null`) and the
    /// network TronWeb should report.
    func sessionDidChange(_ session: DappSessionSnapshot) -> [DappEvent] {
        let account = session.permittedNamespaces.contains(.tron) ? session.accounts[.tron] : nil
        var payload = Self.networkPayload(for: session.accounts[.tron]).objectValue ?? [:]
        payload["account"] = account.flatMap { try? Self.accountPayload(for: $0) } ?? .null

        return [DappEvent(name: "change", payload: .object(payload))]
    }

    /// TronLink's EIP-1193-style numeric codes.
    func wireError(_ error: DappError) -> JSONValue {
        let code: Int
        let message: String
        switch error {
        case .userRejected:
            code = 4001
            message = "User rejected the request."
        case .unauthorized:
            code = 4100
            message = "This account is not connected to this site."
        case .unsupportedMethod:
            code = 4200
            message = "This method is not supported."
        case let .invalidParams(reason):
            code = -32602
            message = reason
        case .disconnected:
            code = 4900
            message = "No Tron account is connected."
        case .chainNotFound:
            code = 4901
            message = "Unrecognized Tron network."
        case let .internalError(reason):
            code = -32603
            message = reason
        case .cardano:
            code = -32603
            message = "Unexpected Cardano error."
        }

        return .object(["code": .number(Double(code)), "message": .string(message)])
    }
}

// MARK: - Connection

extension TronDappProvider {
    static func accountPayload(for account: Account) throws -> JSONValue {
        let address = try TronAddress(string: account.address)
        let hex = String(address.rawBytes.hexEncoded.dropFirst(2))
        return .object(["address": .string(address.string), "hex": .string(hex)])
    }

    /// `chainId` as TronLink reports it (the last 4 bytes of the genesis
    /// block id) plus the node host TronWeb shows; mainnet when no Tron
    /// account is selected.
    static func networkPayload(for account: Account?) -> JSONValue {
        let blockchain = account?.blockchain ?? .tron(.mainnet)
        let host = account?.rpcURLOverride ?? blockchain.rpcURL
        let chainId = if case .tron(.testnet) = blockchain { "0xcd8690dc" } else { "0x2b6653dc" }

        return .object(["chainId": .string(chainId), "host": .string(host.absoluteString)])
    }
}

private extension TronDappProvider {
    func connect(params: JSONValue, context: DappRequestContext) async throws(DappError) -> JSONValue {
        guard let account = await context.session.selectedAccount(.tron) else {
            throw .disconnected
        }

        if await context.session.isPermitted(.tron) {
            return try accountResponse(for: account)
        }

        // A page-load reconnect check: fail quietly instead of prompting.
        if params["onlyIfTrusted"]?.boolValue == true {
            throw .unauthorized
        }

        let result = await context.session.withExclusiveApproval {
            await context.approving.approve(.connect(origin: context.origin, namespace: .tron, account: account))
        }

        switch result {
        case .approved, .approvedWithFees:
            guard await context.session.grantPermission(.tron, origin: context.origin, account: account) else {
                throw .disconnected
            }

            return try accountResponse(for: account)
        case .rejected:
            throw .userRejected
        }
    }

    func accountResponse(for account: Account) throws(DappError) -> JSONValue {
        guard let payload = try? Self.accountPayload(for: account) else {
            throw .internalError("unable to build a Tron account payload")
        }

        return payload
    }

    func authorizedAccount(context: DappRequestContext) async throws(DappError) -> Account {
        guard
            await context.session.isPermitted(.tron),
            let account = await context.session.selectedAccount(.tron)
        else {
            throw .unauthorized
        }

        return account
    }

    func isHardwareBacked(_ account: Account) async throws(DappError) -> Bool {
        do {
            return try await transactionService.isHardwareBacked(account)
        } catch {
            throw .internalError("\(error)")
        }
    }
}

// MARK: - Signing

private extension TronDappProvider {
    /// TronWeb `signMessageV2`. `params.message` is the hex of the bytes
    /// to sign (`providers/tron.js` UTF-8-encodes string messages).
    func signMessage(params: JSONValue, context: DappRequestContext) async throws(DappError) -> JSONValue {
        guard let messageHex = params["message"]?.stringValue, let message = decodeHexData(messageHex) else {
            throw .invalidParams("signMessage expects {message: <hex>}")
        }

        let account = try await authorizedAccount(context: context)

        if try await isHardwareBacked(account) {
            throw await failure(.internalError("Trezor does not support Tron message signing."), context: context)
        }

        let result = await context.session.withExclusiveApproval {
            await context.approving.approve(
                .signMessage(origin: context.origin, namespace: .tron, account: account, preview: .tronMessage(message))
            )
        }

        guard case .approved = result else {
            throw .userRejected
        }

        try await context.authorize(.tron, account: account)
        let signature = try await context.signingService.signMessage(.tronMessage(message), account: account)
        return .object(["signature": .string(signature.hexEncoded)])
    }

    /// TronWeb `trx.sign`: validates and previews `raw_data_hex`, then
    /// returns the bare-hex 65-byte signature over it.
    func signTransaction(params: JSONValue, context: DappRequestContext) async throws(DappError) -> JSONValue {
        let account = try await authorizedAccount(context: context)
        let transaction = try Self.validatedTransaction(params["transaction"], owner: account.address)

        let envelope: Data
        do {
            envelope = try transaction.signingEnvelope()
        } catch {
            throw .internalError("\(error)")
        }

        // Trezor signs its own rebuild of the fields; it must match the
        // previewed bytes exactly.
        if try await isHardwareBacked(account), !transaction.isTrezorReproducible {
            let error = DappError.invalidParams(
                "Trezor can't sign this transaction exactly as built (unsupported fields)."
            )

            throw await failure(error, context: context)
        }

        let preview = await self.preview(of: transaction, account: account)
        let result = await context.session.withExclusiveApproval {
            await context.approving.approve(
                .sendTransaction(origin: context.origin, namespace: .tron, account: account, preview: .tron(preview))
            )
        }

        guard case .approved = result else {
            throw .userRejected
        }

        try await context.authorize(.tron, account: account)

        do {
            let signature = try await transactionService.signTransaction(envelope, account: account)
            return .object(["signature": .string(String(signature.hexEncoded.dropFirst(2)))])
        } catch {
            throw await failure(.internalError("Signing failed: \(Self.describe(error))"), context: context)
        }
    }

    /// Logs `error` and shows it in the browser — dapps often swallow a
    /// rejected signing promise, leaving the user with no feedback.
    func failure(_ error: DappError, context: DappRequestContext) async -> DappError {
        let message = switch error {
        case let .internalError(reason), let .invalidParams(reason): reason
        default: "\(error)"
        }

        printError("Tron dapp request from \(context.origin) failed: \(message)")
        await context.approving.reportFailure(message)
        return error
    }

    static func describe(_ error: any Swift.Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? "\(error)"
    }
}

// MARK: - Validation

extension TronDappProvider {
    /// Decodes `value.raw_data_hex` and checks its owner is `owner` and,
    /// when present, that `value.txID` is its hash.
    static func validatedTransaction(_ value: JSONValue?, owner: String) throws(DappError) -> TronRawTransaction {
        guard
            let rawHex = value?["raw_data_hex"]?.stringValue,
            let rawBytes = decodeHexData(rawHex),
            !rawBytes.isEmpty
        else {
            throw .invalidParams("expects {transaction: {raw_data_hex}}")
        }

        let transaction: TronRawTransaction
        do {
            transaction = try TronRawTransaction(rawBytes: rawBytes)
        } catch {
            throw .invalidParams("unable to parse this transaction: \(error)")
        }

        if let txId = value?["txID"]?.stringValue, decodeHexData(txId) != transaction.txId {
            throw .invalidParams("txID does not match raw_data_hex")
        }

        guard let ownerAddress = try? TronAddress(string: owner), transaction.contract.owner == ownerAddress else {
            throw .unauthorized
        }

        return transaction
    }
}
