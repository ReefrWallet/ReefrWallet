//
//  AptosDappProvider.swift
//  Reefr Wallet
//
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import WalletKit

/// The Aptos Wallet Standard (AIP-62) provider behind `providers/aptos.js`.
/// Method names are this bridge's own wire vocabulary.
///
/// `signTransaction` decodes the dapp's `RawTransaction` fail-closed (entry
/// functions only) and requires its sender and chain ID to match the
/// connected account before any prompt. `signMessage` assembles the AIP-62
/// full message natively, so its `APTOS\n` prefix can never collide with a
/// transaction's signing message.
struct AptosDappProvider: DappProvider {
    static let namespace = DappNamespace.aptos

    /// `DappError.userRejected` on the wire; `aptos.js` maps it to
    /// `{status: 'Rejected'}`.
    static let userRejectedCode = 4001

    private let clientProvider: BlockchainClientProvider
    private let transactionService: TransactionService
    private let chainId: @Sendable (Account) async throws -> UInt8

    /// Dependencies default to the DI container. `chainId` defaults to the
    /// account's node (`/v1` ledger info); tests substitute a constant.
    init(
        clientProvider: BlockchainClientProvider? = nil,
        transactionService: TransactionService? = nil,
        chainId: (@Sendable (Account) async throws -> UInt8)? = nil
    ) {
        let resolvedClientProvider = clientProvider ?? DI.injectOrFail(BlockchainClientProvider.self)
        self.clientProvider = resolvedClientProvider
        self.transactionService = transactionService ?? DI.injectOrFail(TransactionService.self)
        self.chainId = chainId ?? { try await resolvedClientProvider.aptosClient(for: $0).ledgerInfo().chainId }
    }

    func handle(method: String, params: JSONValue, context: DappRequestContext) async throws(DappError) -> JSONValue {
        switch method {
        case "account":
            return try await account(context: context)
        case "connect":
            return try await connect(context: context)
        case "disconnect":
            await context.session.revokePermission(.aptos)
            return .null
        case "network":
            return try await network(context: context)
        case "signMessage":
            return try await signMessage(params: params, context: context)
        case "signTransaction":
            return try await signTransaction(params: params, context: context)
        default:
            throw .unsupportedMethod
        }
    }

    /// `aptos.js` re-reads `account`/`network` on any change; only a
    /// disconnect is reported inline.
    func sessionDidChange(_ session: DappSessionSnapshot) -> [DappEvent] {
        guard session.permittedNamespaces.contains(.aptos), session.accounts[.aptos] != nil else {
            return [DappEvent(name: "change", payload: .object(["disconnected": .bool(true)]))]
        }

        return [DappEvent(name: "change", payload: .null)]
    }

    func wireError(_ error: DappError) -> JSONValue {
        let message = switch error {
        case .userRejected: "User rejected the request."
        case .unauthorized: "This account is not connected to this site."
        case .unsupportedMethod: "This method is not supported."
        case let .invalidParams(reason): reason
        case .disconnected: "No Aptos account is connected."
        case .chainNotFound: "This transaction is for a different Aptos network."
        case let .internalError(reason): reason
        case .cardano: "Unexpected Cardano error."
        }

        if case .userRejected = error {
            return .object(["code": .number(Double(Self.userRejectedCode)), "message": .string(message)])
        }

        return .object(["message": .string(message)])
    }
}

// MARK: - Connection

private extension AptosDappProvider {
    func connect(context: DappRequestContext) async throws(DappError) -> JSONValue {
        guard let account = await context.session.selectedAccount(.aptos) else {
            throw .disconnected
        }

        if await !context.session.isPermitted(.aptos) {
            let result = await context.session.withExclusiveApproval {
                await context.approving.approve(.connect(origin: context.origin, namespace: .aptos, account: account))
            }

            guard case .approved = result else {
                throw .userRejected
            }

            guard await context.session.grantPermission(.aptos, origin: context.origin, account: account) else {
                throw .disconnected
            }
        }

        return .object([
            "account": try await accountJSON(account),
            "network": try await networkJSON(account)
        ])
    }

    /// `{account: null}` until the origin is connected.
    func account(context: DappRequestContext) async throws(DappError) -> JSONValue {
        guard
            await context.session.isPermitted(.aptos),
            let account = await context.session.selectedAccount(.aptos)
        else {
            return .object(["account": .null])
        }

        return .object(["account": try await accountJSON(account)])
    }

    func network(context: DappRequestContext) async throws(DappError) -> JSONValue {
        guard let account = await context.session.selectedAccount(.aptos) else {
            throw .disconnected
        }

        return try await networkJSON(account)
    }

    func accountJSON(_ account: Account) async throws(DappError) -> JSONValue {
        let signer = try await aptosSigner(for: account)

        do {
            let address = try AptosAddress(string: account.address)
            return .object([
                "address": .string(address.rawBytes.base64EncodedString()),
                "addressString": .string(address.string),
                "chain": .string(try Self.chainString(for: account)),
                "publicKey": .string(try signer.publicKeyBytes().base64EncodedString()),
                "publicKeyBcs": .string(try signer.publicKeyBcs().base64EncodedString())
            ])
        } catch {
            throw .internalError("\(error)")
        }
    }

    /// AIP-62 `NetworkInfo`. An RPC override reports `custom`; the chain ID
    /// always comes from the node.
    func networkJSON(_ account: Account) async throws(DappError) -> JSONValue {
        guard case let .aptos(network) = account.blockchain else {
            throw .disconnected
        }

        let id: UInt8
        do {
            id = try await chainId(account)
        } catch {
            throw .internalError("\(error)")
        }

        let name = account.rpcURLOverride == nil ? (network == .mainnet ? "mainnet" : "testnet") : "custom"
        let url = (account.rpcURLOverride ?? network.rpcURL).absoluteString
        return .object(["name": .string(name), "chainId": .number(Double(id)), "url": .string(url)])
    }

    static func chainString(for account: Account) throws -> String {
        guard case let .aptos(network) = account.blockchain else {
            throw DappError.disconnected
        }

        return network == .mainnet ? "aptos:mainnet" : "aptos:testnet"
    }

    /// The origin must be permitted and `addressString` must be the selected account.
    func authorizedAccount(params: JSONValue, context: DappRequestContext) async throws(DappError) -> Account {
        guard
            await context.session.isPermitted(.aptos),
            let account = await context.session.selectedAccount(.aptos)
        else {
            throw .unauthorized
        }

        guard
            let addressString = params["account"]?["address"]?.stringValue,
            let requested = try? AptosAddress(chainString: addressString),
            let selected = try? AptosAddress(string: account.address),
            requested == selected
        else {
            throw .unauthorized
        }

        return account
    }

    func aptosSigner(for account: Account) async throws(DappError) -> AptosPKeySigner {
        let signer: any Signer
        do {
            signer = try await transactionService.makeSigner(for: account)
        } catch ReefrError.notSupported {
            throw .unauthorized
        } catch {
            throw .internalError("\(error)")
        }

        guard let aptosSigner = signer as? AptosPKeySigner else {
            throw .internalError("this account's signer is not an Aptos software signer")
        }

        return aptosSigner
    }
}

// MARK: - Signing

private extension AptosDappProvider {
    func signMessage(params: JSONValue, context: DappRequestContext) async throws(DappError) -> JSONValue {
        guard let message = params["message"]?.stringValue, let nonce = params["nonce"]?.stringValue else {
            throw .invalidParams("signMessage expects {message, nonce}")
        }

        let account = try await authorizedAccount(params: params, context: context)
        var lines = ["APTOS"]
        var response: [String: JSONValue] = ["message": .string(message), "nonce": .string(nonce)]

        if params["address"]?.boolValue == true {
            lines.append("address: \(account.address)")
            response["address"] = .string(account.address)
        }

        if params["application"]?.boolValue == true {
            lines.append("application: \(context.origin)")
            response["application"] = .string(context.origin)
        }

        if params["chainId"]?.boolValue == true {
            let id = try await networkJSON(account)["chainId"] ?? .null
            lines.append("chainId: \(Int(id.numberValue ?? 0))")
            response["chainId"] = id
        }

        lines.append("message: \(message)")
        lines.append("nonce: \(nonce)")
        let fullMessage = lines.joined(separator: "\n")

        let preview = DappMessagePreview.aptosMessage(fullMessage)
        let result = await context.session.withExclusiveApproval {
            await context.approving.approve(
                .signMessage(origin: context.origin, namespace: .aptos, account: account, preview: preview)
            )
        }

        guard case .approved = result else {
            throw .userRejected
        }

        try await context.authorize(.aptos, account: account)
        let signer = try await aptosSigner(for: account)
        let signature = try await context.signingService.signMessage(
            .aptosMessage(Data(fullMessage.utf8)),
            account: account
        )

        response["fullMessage"] = .string(fullMessage)
        response["signature"] = .string(signature.base64EncodedString())
        response["signatureBcs"] = .string(signer.signatureBcs(signature).base64EncodedString())
        return .object(response)
    }

    func signTransaction(params: JSONValue, context: DappRequestContext) async throws(DappError) -> JSONValue {
        guard let base64 = params["rawTransaction"]?.stringValue, let bytes = Data(base64Encoded: base64) else {
            throw .invalidParams("signTransaction expects {rawTransaction, account: {address}}")
        }

        let account = try await authorizedAccount(params: params, context: context)

        guard
            let transaction = try? AptosRawTransaction(bcs: bytes),
            let sender = try? AptosAddress(string: account.address),
            transaction.sender == sender
        else {
            throw .invalidParams("unable to validate this transaction")
        }

        let expectedChainId: UInt8
        do {
            expectedChainId = try await chainId(account)
        } catch {
            throw .internalError("\(error)")
        }

        guard transaction.chainId == expectedChainId else {
            throw .chainNotFound
        }

        let preview = AptosTransactionPreview(rawBytes: bytes, transaction: transaction)
        let result = await context.session.withExclusiveApproval {
            await context.approving.approve(
                .sendTransaction(origin: context.origin, namespace: .aptos, account: account, preview: .aptos(preview))
            )
        }

        guard case .approved = result else {
            throw .userRejected
        }

        try await context.authorize(.aptos, account: account)
        let signer = try await aptosSigner(for: account)

        do {
            let authenticator = try await signer.signAccountAuthenticator(transaction: bytes)
            return .object(["authenticator": .string(authenticator.base64EncodedString())])
        } catch {
            throw .internalError("\(error)")
        }
    }
}
