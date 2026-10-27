//
//  CardanoDappProvider.swift
//  Reefr Wallet
//
//  Created by Andrey Yurkevich on 27.10.26.
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import WalletKit

/// The CIP-30 provider behind `providers/cardano.js` (`window.cardano.reefr`).
///
/// Everything crosses the bridge as hex. Every error leaves this provider as
/// ``DappError/cardano(_:)``: ``DappProvider/wireError(_:)`` doesn't know the
/// method, so each call site converts to the code space the page expects.
///
/// Calls after `enable` are tied to the account that enabled: if the selected
/// account changes, or the permission is revoked, they fail with
/// `APIError.AccountChange` until the dapp calls `enable` again.
struct CardanoDappProvider: DappProvider {
    static let namespace = DappNamespace.cardano

    private let enabledAccounts = CardanoEnabledAccounts()
    private let makeClient: @Sendable (Account) throws -> CardanoClient

    /// Defaults to the global DI container's client provider; tests pass a
    /// factory returning a client over a stubbed session.
    init(makeClient: (@Sendable (Account) throws -> CardanoClient)? = nil) {
        self.makeClient = makeClient ?? { account in
            let provider = DI.injectOrFail(BlockchainClientProvider.self)
            let client = try provider.makeClient(blockchain: account.blockchain, rpcURL: account.rpcURLOverride)
            guard let client = client as? CardanoClient else {
                throw CardanoDappError.internalError("No Cardano client for this account.")
            }

            return client
        }
    }

    func handle(method: String, params: JSONValue, context: DappRequestContext) async throws(DappError) -> JSONValue {
        do {
            return try await dispatch(method: method, params: params, context: context)
        } catch {
            throw .cardano(error)
        }
    }

    /// CIP-30 has no wallet-initiated events.
    func sessionDidChange(_ session: DappSessionSnapshot) -> [DappEvent] {
        []
    }

    func wireError(_ error: DappError) -> JSONValue {
        if case let .cardano(error) = error {
            return error.wire
        }

        return CardanoDappError.internalError(error.errorDescription ?? "Unexpected error.").wire
    }
}

// MARK: - Dispatch

private extension CardanoDappProvider {
    func dispatch(
        method: String,
        params: JSONValue,
        context: DappRequestContext
    ) async throws(CardanoDappError) -> JSONValue {
        let arguments = params.arrayValue ?? []

        switch method {
        case "enable":
            return try await enable(context: context)
        case "isEnabled":
            return .bool(await isEnabled(context: context))
        case "getExtensions":
            return .array([])
        case "getNetworkId":
            return .number(Double(try await authorized(context).descriptor.network.addressNetworkId))
        case "getUtxos":
            return try await getUtxos(arguments, context: context)
        case "getBalance":
            let session = try await authorized(context)
            return .string(try await call { try await session.client.dappBalanceHex(session.descriptor) })
        case "getUsedAddresses":
            return try await getUsedAddresses(arguments, context: context)
        case "getUnusedAddresses":
            return try await getUnusedAddresses(context: context)
        case "getChangeAddress":
            let descriptor = try await authorized(context).descriptor
            return .string(try call { try cardanoAddressBytes(descriptor.receiveAddress.string).cardanoHex })
        case "getRewardAddresses":
            let descriptor = try await authorized(context).descriptor
            return .array([.string(try call { try cardanoAddressBytes(descriptor.stakeAddress).cardanoHex })])
        case "signTx":
            return try await signTx(arguments, context: context)
        case "signData":
            return try await signData(arguments, context: context)
        case "submitTx":
            return try await submitTx(arguments, context: context)
        default:
            throw .invalidRequest("Unsupported method \(method).")
        }
    }
}

// MARK: - Connection

private extension CardanoDappProvider {
    func enable(context: DappRequestContext) async throws(CardanoDappError) -> JSONValue {
        guard let account = await context.session.selectedAccount(.cardano) else {
            throw .refused
        }

        if !(await context.session.isPermitted(.cardano)) {
            let result = await context.session.withExclusiveApproval {
                await context.approving.approve(.connect(origin: context.origin, namespace: .cardano, account: account))
            }

            switch result {
            case .approved, .approvedWithFees:
                guard await context.session.grantPermission(.cardano, origin: context.origin, account: account) else {
                    throw .accountChanged
                }

            case .rejected:
                throw .refused
            }
        }

        await enabledAccounts.set(account.address, origin: context.origin)
        return .bool(true)
    }

    func isEnabled(context: DappRequestContext) async -> Bool {
        guard
            let account = await context.session.selectedAccount(.cardano),
            await context.session.isPermitted(.cardano)
        else {
            return false
        }

        return await enabledAccounts.address(origin: context.origin) == account.address
    }

    /// The account the page enabled, if it is still selected and permitted.
    func authorized(_ context: DappRequestContext) async throws(CardanoDappError) -> Session {
        guard
            let account = await context.session.selectedAccount(.cardano),
            await context.session.isPermitted(.cardano),
            await enabledAccounts.address(origin: context.origin) == account.address
        else {
            throw .accountChanged
        }

        let descriptor = try call { try CardanoAccountDescriptor(string: account.address) }
        let client = try call { try makeClient(account) }

        return Session(account: account, client: client, descriptor: descriptor)
    }

    struct Session {
        let account: Account
        let client: CardanoClient
        let descriptor: CardanoAccountDescriptor
    }
}

// MARK: - Reads

private extension CardanoDappProvider {
    func getUtxos(_ arguments: [JSONValue], context: DappRequestContext) async throws(CardanoDappError) -> JSONValue {
        let session = try await authorized(context)
        let amount = try optionalString(arguments, at: 0)
        let paginate = try pagination(arguments, at: 1)

        let utxos = try await call { try await session.client.dappUtxoHexes(session.descriptor, amountHex: amount) }
        guard let utxos else {
            return .null
        }

        return .array(try page(utxos, paginate).map(JSONValue.string))
    }

    func getUsedAddresses(
        _ arguments: [JSONValue],
        context: DappRequestContext
    ) async throws(CardanoDappError) -> JSONValue {
        let session = try await authorized(context)
        let paginate = try pagination(arguments, at: 0)
        let usage = try await call { try await session.client.addressUsage(session.descriptor) }
        let addresses = try call { try usage.used.map { try cardanoAddressBytes($0.address.string).cardanoHex } }

        return .array(try page(addresses, paginate).map(JSONValue.string))
    }

    func getUnusedAddresses(context: DappRequestContext) async throws(CardanoDappError) -> JSONValue {
        let session = try await authorized(context)
        let usage = try await call { try await session.client.addressUsage(session.descriptor) }
        let address = try call {
            try session.descriptor.address(role: 0, index: usage.firstUnusedExternalIndex())
        }

        return .array([.string(try call { try cardanoAddressBytes(address.string).cardanoHex })])
    }

    /// `[start, start + limit)` of `items`, or a `PaginateError` carrying the
    /// total item count when the page is out of range. Zero-indexed.
    func page(_ items: [String], _ paginate: (page: Int, limit: Int)?) throws(CardanoDappError) -> [String] {
        guard let paginate else {
            return items
        }

        let start = paginate.page * paginate.limit
        guard start < items.count || (start == 0 && items.isEmpty) else {
            throw .paginate(maxSize: items.count)
        }

        return Array(items[min(start, items.count)..<min(start + paginate.limit, items.count)])
    }
}

// MARK: - Transactions

private extension CardanoDappProvider {
    func signTx(_ arguments: [JSONValue], context: DappRequestContext) async throws(CardanoDappError) -> JSONValue {
        let session = try await authorized(context)
        let bytes = try transactionBytes(arguments, at: 0)
        let partialSign = arguments.count > 1 ? (arguments[1].boolValue ?? false) : false

        let transaction: CardanoDappTransaction
        do {
            transaction = try CardanoDappTransaction(decoding: bytes)
        } catch {
            throw .txSign(.proofGeneration, "The transaction could not be decoded: \(error)")
        }

        try validateNetwork(of: transaction, for: session.descriptor)

        let signers = try await call(.txSign) {
            try await session.client.resolveSigners(transaction: bytes, owner: session.descriptor)
        }

        guard !signers.toSign.isEmpty else {
            throw .txSign(.proofGeneration, "This account has no key to sign this transaction with.")
        }

        guard partialSign || signers.isComplete else {
            throw .txSign(.proofGeneration, Self.incomplete(signers))
        }

        let preview = CardanoTransactionPreview(
            missingSignerCount: signers.missingCount + signers.unresolved.count,
            partialSign: partialSign,
            rawBytes: bytes,
            signingPaths: signers.toSign,
            transaction: transaction,
            validWitnessCount: signers.validExistingCount
        )

        let result = await context.session.withExclusiveApproval {
            await context.approving.approve(
                .sendTransaction(
                    origin: context.origin,
                    namespace: .cardano,
                    account: session.account,
                    preview: .cardano(preview)
                )
            )
        }

        guard case .approved = result else {
            throw .txSign(.userDeclined, "The user declined to sign the transaction.")
        }

        let witnesses = try await call(.txSign) {
            try await context.signingService.signCardanoTransaction(
                bytes,
                paths: signers.toSign,
                account: session.account,
                authorize: authorizer(context, account: session.account)
            )
        }

        return .string(witnesses.cardanoHex)
    }

    func submitTx(_ arguments: [JSONValue], context: DappRequestContext) async throws(CardanoDappError) -> JSONValue {
        let session = try await authorized(context)
        let bytes = try transactionBytes(arguments, at: 0)

        let transaction: CardanoDappTransaction
        do {
            transaction = try CardanoDappTransaction(decoding: bytes)
        } catch {
            throw .txSend(.refused, "The transaction could not be decoded: \(error)")
        }

        try validateNetwork(of: transaction, for: session.descriptor, send: true)

        do {
            return .string(try await session.client.submit(rawTransaction: bytes))
        } catch {
            let message = "\(error)"
            throw .txSend(message.localizedCaseInsensitiveContains("rejected") ? .refused : .failure, message)
        }
    }

    /// A transaction that names a network must name this account's.
    func validateNetwork(
        of transaction: CardanoDappTransaction,
        for descriptor: CardanoAccountDescriptor,
        send: Bool = false
    ) throws(CardanoDappError) {
        guard let networkId = transaction.networkId, networkId != descriptor.network.addressNetworkId else {
            return
        }

        let message = "The transaction is for a different Cardano network."
        throw send ? .txSend(.refused, message) : .txSign(.proofGeneration, message)
    }

    static func incomplete(_ signers: CardanoSigners) -> String {
        var parts: [String] = []
        if signers.missingCount > 0 {
            parts.append("\(signers.missingCount) required signer(s) are missing")
        }

        if !signers.unresolved.isEmpty {
            parts.append("\(signers.unresolved.count) requirement(s) could not be checked")
        }

        return parts.joined(separator: " and ") + ". Pass partialSign to sign only this wallet's part."
    }
}

// MARK: - signData

private extension CardanoDappProvider {
    func signData(_ arguments: [JSONValue], context: DappRequestContext) async throws(CardanoDappError) -> JSONValue {
        let session = try await authorized(context)
        guard
            arguments.count >= 2,
            let addressText = arguments[0].stringValue,
            let payloadHex = arguments[1].stringValue
        else {
            throw .invalidRequest("signData expects (address, payload).")
        }

        guard let payload = decodeHexData(payloadHex) else {
            throw .invalidRequest("The payload is not hex.")
        }

        let address = try call(.dataSign) { try Self.addressBytes(addressText) }

        let usage = try await call(.dataSign) { try await session.client.addressUsage(session.descriptor) }
        let path = try call(.dataSign) {
            try cardanoSigningPath(for: address, owner: session.descriptor, usage: usage)
        }

        guard let path else {
            throw .dataSign(.addressNotPK, "This account doesn't hold the key behind that address.")
        }

        let displayAddress = try call(.dataSign) { try cardanoAddressString(address) }
        let result = await context.session.withExclusiveApproval {
            await context.approving.approve(
                .signMessage(
                    origin: context.origin,
                    namespace: .cardano,
                    account: session.account,
                    preview: .cardanoCIP8(
                        address: displayAddress,
                        keyRole: path.role == 2 ? .stake : .payment,
                        payload: payload
                    )
                )
            )
        }

        guard case .approved = result else {
            throw .dataSign(.userDeclined, "The user declined to sign the data.")
        }

        let signed = try await call(.dataSign) {
            try await context.signingService.signCardanoData(
                payload,
                address: address,
                path: path,
                account: session.account,
                authorize: authorizer(context, account: session.account)
            )
        }

        return .object(["key": .string(signed.key.cardanoHex), "signature": .string(signed.signature.cardanoHex)])
    }

    /// CIP-30 passes addresses as hex; some dapps send bech32.
    static func addressBytes(_ text: String) throws -> Data {
        if looksLikeHex(text), let bytes = decodeHexData(text) {
            return bytes
        }

        return try cardanoAddressBytes(text)
    }

    static func looksLikeHex(_ text: String) -> Bool {
        let trimmed = text.hasPrefix("0x") ? String(text.dropFirst(2)) : text

        return !trimmed.isEmpty && trimmed.allSatisfy(\.isHexDigit)
    }
}
