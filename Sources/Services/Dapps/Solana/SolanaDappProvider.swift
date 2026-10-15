//
//  SolanaDappProvider.swift
//  Reefr Wallet
//
//  Created by Andrey Yurkevich on 30.09.26.
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import WalletKit

/// The Solana Wallet Standard provider, following ``SuiDappProvider``'s
/// shape. `providers/solana.js` implements the JS-side registration and
/// feature map, each feature calling back into this provider through the
/// same chain-agnostic `window.__reefr` transport — the method names
/// below (`connect`, `disconnect`, `signMessage`, `signTransaction`,
/// `signAndSendTransaction`) are this bridge's own wire vocabulary, not
/// Wallet Standard's JS-facing feature strings.
///
/// Unlike Sui, a Solana address *is* the Base58 of its ed25519 public
/// key — no signer construction is needed to answer `connect` or build a
/// `sessionDidChange` payload, so (unlike ``SuiDappProvider``) this
/// provider can build the full account list synchronously.
struct SolanaDappProvider: DappProvider {
    static let namespace = DappNamespace.solana

    private let clientProvider: BlockchainClientProvider
    private let transactionService: TransactionService

    /// Every dependency defaults to the global DI container; tests pass
    /// their own isolated instances, mirroring ``SuiDappProvider``'s own
    /// init convention.
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
            return await disconnect(context: context)
        case "signMessage":
            return try await signMessage(params: params, context: context)
        case "signTransaction":
            let result = try await validateAndSign(params: params, context: context)
            let signedBytes = try assembleSignedTransaction(result)
            return .object(["signedTransaction": .string(signedBytes.base64EncodedString())])
        case "signAndSendTransaction":
            return try await signAndSendTransaction(params: params, context: context)
        default:
            throw .unsupportedMethod
        }
    }

    /// A single `"change"` event carrying the complete account list (or an
    /// empty one if permission or the selected account is absent) — unlike
    /// ``SuiDappProvider/sessionDidChange(_:)``, this can be built
    /// synchronously here, so `providers/solana.js` doesn't need an
    /// async re-fetch to react to it.
    func sessionDidChange(_ session: DappSessionSnapshot) -> [DappEvent] {
        guard
            session.permittedNamespaces.contains(.solana),
            let account = session.accounts[.solana],
            let payload = try? Self.accountsPayload(for: account)
        else {
            return [DappEvent(name: "change", payload: .object(["accounts": .array([])]))]
        }

        return [DappEvent(name: "change", payload: payload)]
    }

    /// Wallet Standard defines no numeric error-code convention, so this
    /// is a plain message with no `code` key, matching ``SuiDappProvider``.
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
            message = "No Solana account is connected."
        case .chainNotFound:
            message = "Unrecognized Solana network."
        case let .internalError(reason):
            message = reason
        }

        return .object(["message": .string(message)])
    }
}

// MARK: - Connection

private extension SolanaDappProvider {
    func connect(params: JSONValue, context: DappRequestContext) async throws(DappError) -> JSONValue {
        guard let account = await context.session.selectedAccount(.solana) else {
            throw .disconnected
        }

        if await context.session.isPermitted(.solana) {
            return try accountsResponse(for: account)
        }

        // The legacy `window.solana.connect({onlyIfTrusted: true})` shape
        // (`providers/solana-legacy.js`) asks for a silent reconnect: fail
        // immediately, no approval prompt, if the origin isn't already
        // permitted. `providers/solana.js` never sends this key, so its
        // behavior here is unchanged.
        if params["onlyIfTrusted"]?.boolValue == true {
            throw .unauthorized
        }

        let result = await context.session.withExclusiveApproval {
            await context.approving.approve(.connect(origin: context.origin, namespace: .solana, account: account))
        }

        switch result {
        case .approved, .approvedWithFees:
            guard await context.session.grantPermission(.solana, origin: context.origin, account: account) else {
                throw .disconnected
            }

            return try accountsResponse(for: account)
        case .rejected:
            throw .userRejected
        }
    }

    /// No approval prompt, mirroring ``SuiDappProvider/disconnect(context:)``.
    func disconnect(context: DappRequestContext) async -> JSONValue {
        await context.session.revokePermission(.solana)
        return .null
    }

    func accountsResponse(for account: Account) throws(DappError) -> JSONValue {
        guard let payload = try? Self.accountsPayload(for: account) else {
            throw .internalError("unable to build a Solana account payload")
        }

        return payload
    }

    /// Builds `{accounts: [{address, publicKey, chain}]}` directly from
    /// `account`'s address — a Solana address is the Base58 of its raw
    /// ed25519 public key, so no signer construction is needed the way
    /// ``SuiDappProvider/accountsResponse(account:)`` needs one.
    static func accountsPayload(for account: Account) throws -> JSONValue {
        guard case let .solana(network) = account.blockchain else {
            throw Error.invalidData
        }

        let address = try SolanaAddress(string: account.address)
        return .object([
            "accounts": .array([
                .object([
                    "address": .string(address.string),
                    "publicKey": .string(address.rawBytes.base64EncodedString()),
                    "chain": .string(chainString(for: network))
                ])
            ])
        ])
    }

    static func chainString(for network: SolanaNetwork) -> String {
        switch network {
        case .mainnet: "solana:mainnet"
        case .testnet: "solana:testnet"
        case .devnet: "solana:devnet"
        }
    }

    /// The origin must be permitted, and `addressString` must decode to
    /// the exact same bytes as the currently selected account, before
    /// signing/sending anything. Base58 is case-sensitive, so (unlike
    /// ``SuiDappProvider/authorizedAccount(matching:context:)``) this
    /// compares decoded addresses rather than case-insensitive strings.
    func authorizedAccount(
        matching addressString: String, context: DappRequestContext
    ) async throws(DappError) -> Account {
        guard
            await context.session.isPermitted(.solana),
            let account = await context.session.selectedAccount(.solana),
            let requested = try? SolanaAddress(string: addressString),
            let selected = try? SolanaAddress(string: account.address),
            requested.rawBytes == selected.rawBytes
        else {
            throw .unauthorized
        }

        return account
    }
}

// MARK: - Message signing

private extension SolanaDappProvider {
    func signMessage(params: JSONValue, context: DappRequestContext) async throws(DappError) -> JSONValue {
        guard
            let messageBase64 = params["message"]?.stringValue,
            let addressString = params["account"]?["address"]?.stringValue,
            let messageData = Data(base64Encoded: messageBase64)
        else {
            throw .invalidParams("signMessage expects {message, account: {address}}")
        }

        let account = try await authorizedAccount(matching: addressString, context: context)

        // Fail closed: a `signMessage` request must never be signable as
        // a transaction message or a complete wire transaction — reject
        // outright (before any approval prompt) if it parses as either.
        if (try? SolanaParsedMessage(validating: messageData)) != nil {
            throw .invalidParams("refusing to sign bytes that parse as a Solana transaction message")
        }

        if (try? SolanaWireTransaction(parsing: messageData)) != nil {
            throw .invalidParams("refusing to sign bytes that parse as a complete Solana transaction")
        }

        let preview = DappMessagePreview.solanaMessage(messageData)
        let result = await context.session.withExclusiveApproval {
            await context.approving.approve(
                .signMessage(origin: context.origin, namespace: .solana, account: account, preview: preview)
            )
        }

        guard case .approved = result else {
            throw .userRejected
        }

        let signature = try await context.signingService.signMessage(.solanaMessage(messageData), account: account)
        return .object(["signedMessage": .string(messageBase64), "signature": .string(signature.base64EncodedString())])
    }
}

// MARK: - Transaction signing / sending

/// The result of `validateAndSign` — the shared prefix of `signTransaction`/
/// `signAndSendTransaction`, which differ only in what happens after
/// signing.
private struct SolanaValidatedSignature {
    let account: Account
    let signature: Data
    let transaction: SolanaWireTransaction
}

private extension SolanaDappProvider {
    /// Validates, previews, and (if approved) signs a dapp-supplied
    /// Solana transaction.
    ///
    /// Parsing `params.transaction` and requiring the authorized account
    /// to occupy one of its required-signer slots are signing
    /// preconditions, not just cosmetic preview data: this permits
    /// sponsored transactions (the authorized account need not be the fee
    /// payer) while still rejecting a transaction this account has no
    /// business signing, before any approval prompt.
    func validateAndSign(
        params: JSONValue, context: DappRequestContext
    ) async throws(DappError) -> SolanaValidatedSignature {
        guard
            let transactionBase64 = params["transaction"]?.stringValue,
            let addressString = params["account"]?["address"]?.stringValue,
            let rawBytes = Data(base64Encoded: transactionBase64)
        else {
            throw .invalidParams("expects {transaction, account: {address}}")
        }

        let account = try await authorizedAccount(matching: addressString, context: context)

        if let chainString = params["chain"]?.stringValue {
            guard case let .solana(network) = account.blockchain, chainString == Self.chainString(for: network) else {
                throw .chainNotFound
            }
        }

        let transaction: SolanaWireTransaction
        do {
            transaction = try SolanaWireTransaction(parsing: rawBytes)
        } catch {
            throw .invalidParams("unable to parse this transaction")
        }

        guard
            let authorizedAddress = try? SolanaAddress(string: account.address),
            transaction.staticAccountKeys.prefix(Int(transaction.header.numRequiredSignatures))
                .contains(where: { $0.rawBytes == authorizedAddress.rawBytes })
        else {
            throw .invalidParams("this account is not a required signer of this transaction")
        }

        guard let feePayer = transaction.staticAccountKeys.first else {
            throw .invalidParams("this transaction has no accounts")
        }

        let preview = DappTransactionPreview.solana(SolanaTransactionPreview(
            feePayer: feePayer,
            programIds: Self.programIds(in: transaction),
            rawBytes: rawBytes,
            transaction: transaction
        ))
        let result = await context.session.withExclusiveApproval {
            await context.approving.approve(
                .sendTransaction(origin: context.origin, namespace: .solana, account: account, preview: preview)
            )
        }

        guard case .approved = result else {
            throw .userRejected
        }

        do {
            let envelope = try SolanaUnsignedTransaction(message: transaction.messageBytes).encoded()
            let signature = try await transactionService.signTransaction(envelope, account: account)
            return SolanaValidatedSignature(account: account, signature: signature, transaction: transaction)
        } catch {
            throw .internalError("\(error)")
        }
    }

    /// Every static account referenced as an instruction's `programIdIndex`
    /// — deduplicated, first-seen order. Rule 11 of ``SolanaWireTransaction``'s
    /// parser already guarantees every `programIdIndex` is a static key.
    static func programIds(in transaction: SolanaWireTransaction) -> [SolanaAddress] {
        var seen = Set<Data>()
        var programIds: [SolanaAddress] = []
        for instruction in transaction.instructions {
            let programId = transaction.staticAccountKeys[Int(instruction.programIdIndex)]
            if seen.insert(programId.rawBytes).inserted {
                programIds.append(programId)
            }
        }

        return programIds
    }

    /// Replaces `result.account`'s signer slot with `result.signature`,
    /// preserving every co-signer signature already present.
    func assembleSignedTransaction(_ result: SolanaValidatedSignature) throws(DappError) -> Data {
        do {
            let address = try SolanaAddress(string: result.account.address)
            return try result.transaction.signed(by: address, signature: result.signature)
        } catch {
            throw .internalError("\(error)")
        }
    }

    /// Submits the signed transaction and returns the RPC's own broadcast
    /// signature — **not** `result.signature` (this account's signer-slot
    /// signature): in a sponsored transaction this account may occupy a
    /// non-zero signer slot, while Solana's transaction
    /// signature/identifier is always the slot-0 (fee payer) signature.
    func signAndSendTransaction(params: JSONValue, context: DappRequestContext) async throws(DappError) -> JSONValue {
        let options = try Self.parseSendOptions(params["options"])
        let result = try await validateAndSign(params: params, context: context)
        let signedBytes = try assembleSignedTransaction(result)

        let signatureBase58: String
        do {
            let client = try clientProvider.solanaClient(for: result.account)
            signatureBase58 = try await client.sendTransaction(signedBytes, options: options)
        } catch {
            throw .internalError("\(error)")
        }

        guard let signatureBytes = try? Base58.decode(signatureBase58), signatureBytes.count == 64 else {
            throw .internalError("Solana RPC returned a signature that could not be decoded to 64 bytes")
        }

        return .object(["signature": .string(signatureBytes.base64EncodedString())])
    }

    /// Validates Wallet Standard's `solana:signAndSendTransaction` options
    /// object before any approval prompt — an unsupported commitment or a
    /// malformed numeric option is a request error, not a signing
    /// decision for the user to weigh in on.
    static func parseSendOptions(_ value: JSONValue?) throws(DappError) -> SolanaSendTransactionOptions {
        guard let value else {
            return SolanaSendTransactionOptions()
        }

        guard case let .object(fields) = value else {
            throw .invalidParams("options must be an object")
        }

        return SolanaSendTransactionOptions(
            commitment: try commitment(fields, "commitment"),
            maxRetries: try nonNegativeUInt(fields, "maxRetries"),
            minContextSlot: try nonNegativeUInt64(fields, "minContextSlot"),
            preflightCommitment: try commitment(fields, "preflightCommitment"),
            skipPreflight: try boolean(fields, "skipPreflight")
        )
    }

    static func commitment(_ fields: [String: JSONValue], _ key: String) throws(DappError) -> SolanaCommitment? {
        guard let raw = fields[key] else {
            return nil
        }

        guard case let .string(string) = raw, let commitment = SolanaCommitment(rawValue: string) else {
            throw .invalidParams("unsupported value for \(key)")
        }

        return commitment
    }

    static func boolean(_ fields: [String: JSONValue], _ key: String) throws(DappError) -> Bool? {
        guard let raw = fields[key] else {
            return nil
        }

        guard case let .bool(value) = raw else {
            throw .invalidParams("\(key) must be a boolean")
        }

        return value
    }

    static func nonNegativeUInt(_ fields: [String: JSONValue], _ key: String) throws(DappError) -> UInt? {
        guard let raw = fields[key] else {
            return nil
        }

        guard
            case let .number(double) = raw, double >= 0, double.truncatingRemainder(dividingBy: 1) == 0,
            let value = UInt(exactly: double)
        else {
            throw .invalidParams("\(key) must be a non-negative integer")
        }

        return value
    }

    static func nonNegativeUInt64(_ fields: [String: JSONValue], _ key: String) throws(DappError) -> UInt64? {
        guard let raw = fields[key] else {
            return nil
        }

        guard
            case let .number(double) = raw, double >= 0, double.truncatingRemainder(dividingBy: 1) == 0,
            let value = UInt64(exactly: double)
        else {
            throw .invalidParams("\(key) must be a non-negative integer")
        }

        return value
    }
}
