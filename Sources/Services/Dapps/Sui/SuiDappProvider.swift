//
//  SuiDappProvider.swift
//  Reefr Wallet
//
//  Created by Andrey Yurkevich on 30.09.26.
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import WalletKit

/// The Sui Wallet Standard provider — the second ``DappProvider``
/// conformer, after ``EthereumDappProvider``. Unlike EIP-1193's
/// message-passing RPC, Wallet Standard registers a JS `Wallet` object
/// into the page; `providers/sui.js` implements that registration and
/// its `features` map, each feature calling back into this provider
/// through the same chain-agnostic `window.__reefr` transport
/// `providers/ethereum.js` already uses — the method names below
/// (`connect`, `disconnect`, `signPersonalMessage`, `signTransaction`,
/// `signAndExecuteTransaction`) are this bridge's own wire vocabulary,
/// not Wallet Standard's JS-facing feature strings.
///
/// `signTransaction`/`signAndExecuteTransaction` hand a dapp's
/// `Transaction` JSON (per ADR-023, correcting ADR-021's wrong premise
/// that `toJSON()` already returns BCS bytes) to `sui-transaction-
/// builder.js`, which resolves it into real BCS bytes the same way
/// `@mysten/sui`'s own `Transaction.build({client})` does — except the
/// "client" is this provider's own read-only `get*`/`simulateTransaction`
/// methods below, not a JSON-RPC `SuiClient`. Native still fully decodes
/// and validates the resulting bytes before ever signing; a bug in the
/// JS builder can only make a transaction fail to validate, never sign
/// something unvalidated.
struct SuiDappProvider: DappProvider {
    static let namespace = DappNamespace.sui

    private let clientProvider: BlockchainClientProvider
    private let transactionService: TransactionService
    private let chainClient: @Sendable (Account) throws -> any SuiDappChainQuerying

    /// Every dependency defaults to the global DI container; tests pass
    /// their own isolated instances, mirroring ``EthereumDappProvider``'s
    /// own init convention. `chainClient` defaults to
    /// `clientProvider.suiClient(for:)`; tests substitute a fake
    /// ``SuiDappChainQuerying`` to exercise the lookup methods offline.
    init(
        clientProvider: BlockchainClientProvider? = nil,
        transactionService: TransactionService? = nil,
        chainClient: (@Sendable (Account) throws -> any SuiDappChainQuerying)? = nil
    ) {
        let resolvedClientProvider = clientProvider ?? DI.injectOrFail(BlockchainClientProvider.self)
        self.clientProvider = resolvedClientProvider
        self.transactionService = transactionService ?? DI.injectOrFail(TransactionService.self)
        self.chainClient = chainClient ?? { try resolvedClientProvider.suiClient(for: $0) }
    }

    func handle(method: String, params: JSONValue, context: DappRequestContext) async throws(DappError) -> JSONValue {
        switch method {
        case "connect":
            return try await connect(context: context)
        case "disconnect":
            return await disconnect(context: context)
        case "getCoins":
            return try await getCoins(params: params, context: context)
        case "getMoveFunction":
            return try await getMoveFunction(params: params, context: context)
        case "getObjects":
            return try await getObjects(params: params, context: context)
        case "getReferenceGasPrice":
            return try await getReferenceGasPrice(params: params, context: context)
        case "signPersonalMessage":
            return try await signPersonalMessage(params: params, context: context)
        case "signTransaction":
            let result = try await validateAndSign(params: params, context: context)
            return .object([
                "bytes": .string(result.bytesBase64),
                "signature": .string(result.signature.base64EncodedString())
            ])
        case "signAndExecuteTransaction":
            return try await signAndExecuteTransaction(params: params, context: context)
        case "simulateTransaction":
            return try await simulateTransaction(params: params, context: context)
        default:
            throw .unsupportedMethod
        }
    }

    /// A single `"change"` event, mirroring `standard:events`'
    /// change-notification role — but unlike Ethereum's
    /// `accountsChanged`/`chainChanged`/`disconnect` trio, this payload
    /// deliberately carries only enough to tell `sui.js` whether it's
    /// now disconnected. Building a full `WalletAccount` (with its
    /// public key) needs an async `TransactionService.makeSigner` call
    /// this synchronous method can't make; `sui.js` re-derives the full
    /// account list by calling `connect` again when it receives a
    /// `"change"` it needs to react to, which is safe to call repeatedly
    /// — an already-permitted origin's `connect` never re-prompts.
    func sessionDidChange(_ session: DappSessionSnapshot) -> [DappEvent] {
        guard session.permittedNamespaces.contains(.sui), session.accounts[.sui] != nil else {
            return [DappEvent(name: "change", payload: .object(["accounts": .array([])]))]
        }

        return [DappEvent(name: "change", payload: .null)]
    }

    /// Wallet Standard defines no numeric error-code convention (unlike
    /// EIP-1193's 4001/4100/...), so this is a plain message with no
    /// `code` key — `bridge.js`'s `request()` already tolerates a
    /// missing `code` on its fallback error object.
    func wireError(_ error: DappError) -> JSONValue {
        let message: String
        switch error {
        case .userRejected:
            message = "User rejected the request."
        case .unauthorized:
            message = "This account is not connected to this site."
        case .unsupportedMethod:
            message = "This method is not supported."
        case let .invalidParams(reason):
            message = reason
        case .disconnected:
            message = "No Sui account is connected."
        case .chainNotFound:
            message = "Unrecognized Sui network."
        case let .internalError(reason):
            message = reason
        }

        return .object(["message": .string(message)])
    }
}

// MARK: - Connection

private extension SuiDappProvider {
    func connect(context: DappRequestContext) async throws(DappError) -> JSONValue {
        guard let account = await context.session.selectedAccount(.sui) else {
            throw .disconnected
        }

        if await context.session.isPermitted(.sui) {
            return try await accountsResponse(account: account)
        }

        let result = await context.session.withExclusiveApproval {
            await context.approving.approve(.connect(origin: context.origin, namespace: .sui, account: account))
        }

        switch result {
        case .approved, .approvedWithFees:
            guard await context.session.grantPermission(.sui, origin: context.origin, account: account) else {
                throw .disconnected
            }

            return try await accountsResponse(account: account)
        case .rejected:
            throw .userRejected
        }
    }

    /// No approval prompt, mirroring how wallets generally don't prompt
    /// on disconnect — the dapp is giving up access it already had, not
    /// asking for something new.
    func disconnect(context: DappRequestContext) async -> JSONValue {
        await context.session.revokePermission(.sui)
        return .null
    }

    /// Builds the `{accounts: [{address, publicKey, chain}]}` response
    /// `connect` returns — needs `account`'s public key, which (unlike
    /// its address) isn't stored on the app's own `Account` model, so
    /// this derives it the same way signing does:
    /// `TransactionService.makeSigner(for:)`'s returned `Signer.account`
    /// (WalletKit's own `Account`, not the app's) always carries one.
    func accountsResponse(account: Account) async throws(DappError) -> JSONValue {
        guard case let .sui(network) = account.blockchain else {
            throw .disconnected
        }

        let publicKeyBase64: String
        do {
            publicKeyBase64 = try await transactionService.withSigner(for: account) { signer in
                signer.account.publicKey.rawBytes.base64EncodedString()
            }
        } catch {
            throw .internalError("\(error)")
        }

        return .object([
            "accounts": .array([
                .object([
                    "address": .string(account.address),
                    "publicKey": .string(publicKeyBase64),
                    "chain": .string(Self.chainString(for: network))
                ])
            ])
        ])
    }

    static func chainString(for network: SuiNetwork) -> String {
        switch network {
        case .mainnet: "sui:mainnet"
        case .testnet: "sui:testnet"
        }
    }

    /// The origin must be permitted, and `addressString` must equal the
    /// currently selected account, before signing/sending anything.
    func authorizedAccount(
        matching addressString: String, context: DappRequestContext
    ) async throws(DappError) -> Account {
        guard
            await context.session.isPermitted(.sui),
            let account = await context.session.selectedAccount(.sui)
        else {
            throw .unauthorized
        }

        guard account.address.caseInsensitiveCompare(addressString) == .orderedSame else {
            throw .unauthorized
        }

        return account
    }
}

// MARK: - Chain queries (read-only)

/// The chain lookups `providers/sui.js` maps onto the bundled
/// `@mysten/sui` `Transaction.build({client})`'s `client.core` to resolve a
/// dapp's `Transaction` JSON into BCS. ``SuiGRPCClient`` conforms via an
/// empty extension below; tests substitute a fake.
protocol SuiDappChainQuerying: Sendable {
    func ownedCoins(of address: SuiAddress, coinType: String) async throws -> [SuiCoinObject]
    func objects(ids: [String]) async throws -> [SuiObjectInfo]
    func moveFunction(package: String, module: String, name: String) async throws -> SuiMoveFunctionSignature
    func referenceGasPrice() async throws -> UInt64
    func gasCostSummary(transactionData: Data) async throws -> SuiGasCostSummary
}

extension SuiGRPCClient: SuiDappChainQuerying {}

private extension SuiDappProvider {
    /// Every lookup is scoped to `params.account.address`, reusing
    /// ``authorizedAccount(matching:context:)`` — the same
    /// permitted-origin-and-matches-selected-account check
    /// `signTransaction`/`signPersonalMessage` already require, so a
    /// lookup method can't be used to probe an account the dapp was
    /// never given.
    func authorizedQueryAccount(params: JSONValue, context: DappRequestContext) async throws(DappError) -> Account {
        guard let addressString = params["account"]?["address"]?.stringValue else {
            throw .invalidParams("expects {account: {address}}")
        }

        return try await authorizedAccount(matching: addressString, context: context)
    }

    /// Maps a thrown ``WalletKitError``/other error from a chain lookup
    /// into ``DappError/internalError(_:)`` — these are read-only
    /// lookups, never user-rejectable, so every failure path is
    /// "something went wrong", not "the user said no".
    func query<Result>(
        params: JSONValue, context: DappRequestContext,
        _ body: (Account, any SuiDappChainQuerying) async throws -> Result
    ) async throws(DappError) -> Result {
        let account = try await authorizedQueryAccount(params: params, context: context)
        do {
            return try await body(account, chainClient(account))
        } catch {
            throw .internalError("\(error)")
        }
    }

    func getCoins(params: JSONValue, context: DappRequestContext) async throws(DappError) -> JSONValue {
        guard let coinType = params["coinType"]?.stringValue else {
            throw .invalidParams("getCoins expects {coinType, account: {address}}")
        }

        let coins = try await query(params: params, context: context) { account, client in
            try await client.ownedCoins(of: SuiAddress(string: account.address), coinType: coinType)
        }

        return .object(["coins": .array(coins.map(SuiDappChainQueryJSON.jsonValue))])
    }

    func getObjects(params: JSONValue, context: DappRequestContext) async throws(DappError) -> JSONValue {
        guard let ids = params["objectIds"]?.arrayValue?.compactMap(\.stringValue), !ids.isEmpty else {
            throw .invalidParams("getObjects expects {objectIds, account: {address}}")
        }

        guard ids.count <= 50 else {
            throw .invalidParams("getObjects accepts at most 50 object ids per call")
        }

        let objects = try await query(params: params, context: context) { _, client in
            try await client.objects(ids: ids)
        }

        return .object(["objects": .array(objects.map(SuiDappChainQueryJSON.jsonValue))])
    }

    func getMoveFunction(params: JSONValue, context: DappRequestContext) async throws(DappError) -> JSONValue {
        guard
            let package = params["package"]?.stringValue,
            let module = params["module"]?.stringValue,
            let function = params["function"]?.stringValue
        else {
            throw .invalidParams("getMoveFunction expects {package, module, function, account: {address}}")
        }

        let signature = try await query(params: params, context: context) { _, client in
            try await client.moveFunction(package: package, module: module, name: function)
        }

        return .object(["parameters": .array(signature.parameters.map(SuiDappChainQueryJSON.jsonValue))])
    }

    func getReferenceGasPrice(params: JSONValue, context: DappRequestContext) async throws(DappError) -> JSONValue {
        let price = try await query(params: params, context: context) { _, client in
            try await client.referenceGasPrice()
        }

        return .object(["price": .string(String(price))])
    }

    /// Simulates a dapp transaction to size its gas budget — unlike
    /// `signTransaction`'s `validateAndSign`, this never signs or
    /// prompts, but the bytes still have to decode and name the
    /// authorized account as sender first: simulation isn't a reason to
    /// relax the "never touch unvalidated bytes" rule.
    func simulateTransaction(params: JSONValue, context: DappRequestContext) async throws(DappError) -> JSONValue {
        guard
            let bytesBase64 = params["transactionBytes"]?.stringValue,
            let bytes = Data(base64Encoded: bytesBase64)
        else {
            throw .invalidParams("simulateTransaction expects {transactionBytes, account: {address}}")
        }

        let account = try await authorizedQueryAccount(params: params, context: context)
        guard
            let summary = SuiTransactionDataDecoder.summarize(bytes),
            summary.sender.string.caseInsensitiveCompare(account.address) == .orderedSame
        else {
            throw .invalidParams("unable to validate this transaction")
        }

        do {
            let cost = try await chainClient(account).gasCostSummary(transactionData: bytes)
            return .object([
                "computationCost": .string(String(cost.computationCost)),
                "storageCost": .string(String(cost.storageCost)),
                "storageRebate": .string(String(cost.storageRebate))
            ])
        } catch {
            throw .internalError("\(error)")
        }
    }
}

// MARK: - Message signing

private extension SuiDappProvider {
    func signPersonalMessage(params: JSONValue, context: DappRequestContext) async throws(DappError) -> JSONValue {
        guard
            let messageBase64 = params["message"]?.stringValue,
            let addressString = params["account"]?["address"]?.stringValue,
            let messageData = Data(base64Encoded: messageBase64)
        else {
            throw .invalidParams("signPersonalMessage expects {message, account: {address}}")
        }

        let account = try await authorizedAccount(matching: addressString, context: context)
        let preview = DappMessagePreview.suiPersonal(messageData)

        let result = await context.session.withExclusiveApproval {
            await context.approving.approve(
                .signMessage(origin: context.origin, namespace: .sui, account: account, preview: preview)
            )
        }

        guard case .approved = result else {
            throw .userRejected
        }

        let signature = try await context.signingService.signMessage(.suiPersonal(messageData), account: account)
        return .object(["bytes": .string(messageBase64), "signature": .string(signature.base64EncodedString())])
    }
}

// MARK: - Transaction signing / execution

/// The result of `validateAndSign` — the shared prefix of
/// `signTransaction`/`signAndExecuteTransaction`, which differ only in
/// what happens after signing.
private struct SuiValidatedSignature {
    let bytes: Data
    let bytesBase64: String
    let account: Account
    let signature: Data
}

private extension SuiDappProvider {
    /// Validates, previews, and (if approved) signs a dapp-supplied Sui
    /// transaction — the shared prefix of `signTransaction` and
    /// `signAndExecuteTransaction`, which differ only in what happens
    /// after signing (return the signature, or also broadcast it).
    ///
    /// Decoding `params.transactionBytes` and checking its sender is a
    /// signing precondition, not just cosmetic preview data: a
    /// transaction that fails to decode, or whose decoded sender
    /// doesn't match the authorized account, is rejected here — before
    /// any approval prompt — so an unvalidated blob never reaches the
    /// signer.
    func validateAndSign(
        params: JSONValue, context: DappRequestContext
    ) async throws(DappError) -> SuiValidatedSignature {
        guard
            let bytesBase64 = params["transactionBytes"]?.stringValue,
            let addressString = params["account"]?["address"]?.stringValue,
            let bytes = Data(base64Encoded: bytesBase64)
        else {
            throw .invalidParams("expects {transactionBytes, account: {address}}")
        }

        let account = try await authorizedAccount(matching: addressString, context: context)

        if let chainString = params["chain"]?.stringValue {
            guard case let .sui(network) = account.blockchain, chainString == Self.chainString(for: network) else {
                throw .chainNotFound
            }
        }

        let authorizedAddress: SuiAddress
        do {
            authorizedAddress = try SuiAddress(string: account.address)
        } catch {
            throw .internalError("\(error)")
        }

        guard
            let summary = SuiTransactionDataDecoder.summarize(bytes),
            summary.gasOwner == authorizedAddress,
            summary.sender == authorizedAddress
        else {
            throw .invalidParams("unable to validate this transaction")
        }

        let preview = DappTransactionPreview.sui(SuiTransactionPreview(rawBytes: bytes, summary: summary))
        let result = await context.session.withExclusiveApproval {
            await context.approving.approve(
                .sendTransaction(origin: context.origin, namespace: .sui, account: account, preview: preview)
            )
        }

        guard case .approved = result else {
            throw .userRejected
        }

        do {
            let signature = try await transactionService.signTransaction(bytes, account: account)
            return SuiValidatedSignature(bytes: bytes, bytesBase64: bytesBase64, account: account, signature: signature)
        } catch {
            throw .internalError("\(error)")
        }
    }

    /// Signs, then broadcasts and fetches execution effects in one
    /// round trip (`SuiGRPCClient.executeTransactionWithEffects`) — the
    /// full Wallet Standard `sui:signAndExecuteTransaction` response
    /// shape (`bytes`, `signature`, `digest`, `effects`).
    func signAndExecuteTransaction(
        params: JSONValue, context: DappRequestContext
    ) async throws(DappError) -> JSONValue {
        let result = try await validateAndSign(params: params, context: context)

        do {
            let client = try clientProvider.suiClient(for: result.account)
            let (digest, effects) = try await client.executeTransactionWithEffects(
                transactionData: result.bytes, signature: result.signature
            )

            return .object([
                "bytes": .string(result.bytesBase64),
                "signature": .string(result.signature.base64EncodedString()),
                "digest": .string(digest),
                "effects": .string(effects.base64EncodedString())
            ])
        } catch {
            throw .internalError("\(error)")
        }
    }
}
