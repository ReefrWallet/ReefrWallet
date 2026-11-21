//
//  EthereumDappProvider.swift
//  Reefr Wallet
//
//  Created by Andrey Yurkevich on 25.09.26.
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import WalletKit

/// The EIP-1193 (`window.ethereum`)/EIP-6963 provider — the first
/// ``DappProvider`` conformer. Later chains (Solana/Sui, Tron, Cardano,
/// Bitcoin) plug in the same way, without touching ``DappBridge``,
/// ``DappSession``, or ``DappApproving``.
struct EthereumDappProvider: DappProvider {
    static let namespace = DappNamespace.ethereum

    /// Read-only methods passed straight through to the account's RPC
    /// endpoint — no approval, since they don't touch the key or send
    /// anything.
    private static let readOnlyAllowlist: Set<String> = [
        "eth_blockNumber", "eth_call", "eth_estimateGas", "eth_feeHistory", "eth_gasPrice",
        "eth_getBalance", "eth_getBlockByHash", "eth_getBlockByNumber", "eth_getCode", "eth_getLogs",
        "eth_getStorageAt", "eth_getTransactionByHash", "eth_getTransactionByBlockHashAndIndex",
        "eth_getTransactionByBlockNumberAndIndex", "eth_getTransactionCount", "eth_getTransactionReceipt",
        "eth_maxPriorityFeePerGas"
    ]

    private let databaseService: DatabaseService
    private let clientProvider: BlockchainClientProvider
    private let feeEstimationService: FeeEstimationService
    private let transactionService: TransactionService

    /// Every dependency defaults to the global DI container; tests pass
    /// their own isolated instances (mirroring `TransactionService`'s
    /// own `init(databaseService:)` override convention) so they don't
    /// share state with the app's real database.
    init(
        databaseService: DatabaseService? = nil,
        clientProvider: BlockchainClientProvider? = nil,
        feeEstimationService: FeeEstimationService? = nil,
        transactionService: TransactionService? = nil
    ) {
        self.databaseService = databaseService ?? DI.injectOrFail(DatabaseService.self)
        self.clientProvider = clientProvider ?? DI.injectOrFail(BlockchainClientProvider.self)
        self.feeEstimationService = feeEstimationService ?? DI.injectOrFail(FeeEstimationService.self)
        self.transactionService = transactionService ?? DI.injectOrFail(TransactionService.self)
    }

    func isConnectRequest(method: String, params: JSONValue) -> Bool {
        method == "eth_requestAccounts" || method == "wallet_requestPermissions"
    }

    func handle(method: String, params: JSONValue, context: DappRequestContext) async throws(DappError) -> JSONValue {
        Logger.verbose("Eth handle: \(method)")

        switch method {
        case "eth_requestAccounts":
            return try await requestAccounts(context: context)
        case "eth_accounts":
            return await currentAccounts(context: context)
        case "wallet_requestPermissions":
            return try await requestPermissions(params: params, context: context)
        case "wallet_getPermissions":
            return await currentPermissions(context: context)
        case "eth_chainId":
            return try await chainIdHex(context: context)
        case "net_version":
            return try await netVersion(context: context)
        case "wallet_switchEthereumChain":
            return try await switchEthereumChain(params: params, context: context)
        case "personal_sign":
            return try await personalSign(params: params, context: context)
        case "eth_signTypedData_v4":
            return try await signTypedData(params: params, context: context)
        case "eth_sendTransaction":
            return try await sendTransaction(params: params, context: context)
        case let method where Self.readOnlyAllowlist.contains(method):
            return try await passthrough(method: method, params: params, context: context)
        default:
            // Includes `wallet_addEthereumChain` and the legacy `eth_sign`.
            throw .unsupportedMethod
        }
    }

    func sessionDidChange(_ session: DappSessionSnapshot) -> [DappEvent] {
        guard session.permittedNamespaces.contains(.ethereum), let account = session.accounts[.ethereum] else {
            return [
                DappEvent(name: "accountsChanged", payload: .array([])),
                DappEvent(name: "disconnect", payload: .null)
            ]
        }

        var events = [DappEvent(name: "accountsChanged", payload: .array([.string(account.address)]))]
        if case let .evm(chain) = account.blockchain {
            events.append(DappEvent(name: "chainChanged", payload: .string(hexQuantity(chain.chainId))))
        }

        return events
    }

    func wireError(_ error: DappError) -> JSONValue {
        let code: Int
        let message: String
        switch error {
        case .userRejected:
            code = 4001
            message = "User rejected the request."
        case .unauthorized:
            code = 4100
            message = "The requested method and/or account has not been authorized by the user."
        case .unsupportedMethod:
            code = 4200
            message = "The requested method is not supported by this Ethereum provider."
        case .disconnected:
            code = 4900
            message = "The provider is disconnected from all chains."
        case .chainNotFound:
            code = 4902
            message = "Unrecognized chain ID."
        case let .invalidParams(reason):
            code = -32602
            message = reason
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

private extension EthereumDappProvider {
    func requestAccounts(context: DappRequestContext) async throws(DappError) -> JSONValue {
        guard let account = await context.session.selectedAccount(.ethereum) else {
            throw .disconnected
        }

        if await context.session.isPermitted(.ethereum) {
            return .array([.string(account.address)])
        }

        let result = await context.session.withExclusiveApproval {
            await context.approving.approve(.connect(origin: context.origin, namespace: .ethereum, account: account))
        }

        switch result {
        case .approved, .approvedWithFees:
            guard await context.session.grantPermission(.ethereum, origin: context.origin, account: account) else {
                throw .disconnected
            }

            return .array([.string(account.address)])
        case .rejected:
            throw .userRejected
        }
    }

    func currentAccounts(context: DappRequestContext) async -> JSONValue {
        guard
            await context.session.isPermitted(.ethereum),
            let account = await context.session.selectedAccount(.ethereum)
        else {
            return .array([])
        }

        return .array([.string(account.address)])
    }

    /// EIP-2255: requests capabilities from the payload's single
    /// `PermissionRequest` object (`{ [methodName]: { [caveatName]: any } }`)
    /// — rejecting anything besides exactly one such object requesting
    /// only the `eth_accounts` capability (with an object caveat value),
    /// since that's the only capability this provider grants — then
    /// reports the grant back as a `RequestedPermission`
    /// (`parentCapability`/`date`), not the bare addresses
    /// `eth_requestAccounts` returns.
    func requestPermissions(params: JSONValue, context: DappRequestContext) async throws(DappError) -> JSONValue {
        guard
            params.arrayValue?.count == 1,
            let requestedCapabilities = params[0]?.objectValue,
            !requestedCapabilities.isEmpty,
            requestedCapabilities.keys.allSatisfy({ $0 == "eth_accounts" }),
            requestedCapabilities["eth_accounts"]?.objectValue != nil
        else {
            throw .invalidParams(
                "wallet_requestPermissions expects a single PermissionRequest object requesting only eth_accounts"
            )
        }

        _ = try await requestAccounts(context: context)

        return .array([
            .object([
                "parentCapability": .string("eth_accounts"),
                "date": .number(Date().timeIntervalSince1970 * 1000)
            ])
        ])
    }

    /// EIP-2255: the `Permission` objects (`invoker`/`parentCapability`/
    /// `caveats`) currently granted to this origin — empty when nothing
    /// has been granted yet.
    func currentPermissions(context: DappRequestContext) async -> JSONValue {
        guard
            await context.session.isPermitted(.ethereum),
            let account = await context.session.selectedAccount(.ethereum)
        else {
            return .array([])
        }

        return .array([
            .object([
                "invoker": .string(context.origin),
                "parentCapability": .string("eth_accounts"),
                "caveats": .array([
                    .object([
                        "type": .string("restrictReturnedAccounts"),
                        "value": .array([.string(account.address)])
                    ])
                ])
            ])
        ])
    }

    /// The origin must be permitted, and `from` must equal the currently
    /// selected account, before signing/sending anything.
    func authorizedAccount(
        matching addressString: String, context: DappRequestContext
    ) async throws(DappError) -> Account {
        guard
            await context.session.isPermitted(.ethereum),
            let account = await context.session.selectedAccount(.ethereum)
        else {
            let details = await context.session.diagnostics(.ethereum)
            Logger.verbose("Eth unauthorized: not permitted, requested \(addressString); \(details)")

            throw .unauthorized
        }

        guard account.address.caseInsensitiveCompare(addressString) == .orderedSame else {
            let details = await context.session.diagnostics(.ethereum)
            Logger.verbose("Eth unauthorized: requested \(addressString) != selected \(account.address); \(details)")

            throw .unauthorized
        }

        return account
    }
}

// MARK: - Chain

private extension EthereumDappProvider {
    func chainIdHex(context: DappRequestContext) async throws(DappError) -> JSONValue {
        guard let account = await context.session.selectedAccount(.ethereum), case let .evm(chain) = account.blockchain
        else {
            throw .disconnected
        }

        return .string(hexQuantity(chain.chainId))
    }

    func netVersion(context: DappRequestContext) async throws(DappError) -> JSONValue {
        guard let account = await context.session.selectedAccount(.ethereum), case let .evm(chain) = account.blockchain
        else {
            throw .disconnected
        }

        return .string(String(chain.chainId))
    }

    /// Switches to the account sharing the current one's keystore and
    /// derivation path, on `params`' requested chain ID — no approval
    /// prompt, since it's the same key the user already trusts this
    /// origin with (via the carry-forward in
    /// `DappSession/setActiveAccount(_:)`).
    func switchEthereumChain(params: JSONValue, context: DappRequestContext) async throws(DappError) -> JSONValue {
        guard
            let requestedChainIdHex = params[0]?["chainId"]?.stringValue,
            let requestedChainId = parseQuantity(requestedChainIdHex),
            let targetChainId = UInt64(exactly: requestedChainId)
        else {
            throw .invalidParams("wallet_switchEthereumChain expects [{chainId}]")
        }

        guard let currentAccount = await context.session.selectedAccount(.ethereum) else {
            throw .disconnected
        }

        // Only an origin already connected for `.ethereum` may move the
        // browser to a sibling account — otherwise any page could switch
        // the active chain/account without ever requesting access.
        guard await context.session.isPermitted(.ethereum) else {
            let details = await context.session.diagnostics(.ethereum)
            Logger.verbose("Eth switch unauthorized: \(details)")
            throw .unauthorized
        }

        guard case .evm = currentAccount.blockchain else {
            throw .disconnected
        }

        let target = Blockchain.evm(EVMBlockchain(chainId: targetChainId))
        let siblings: [Account]
        do {
            siblings = try await databaseService.fetchAccounts(
                keyStoreId: currentAccount.keyStoreId, blockchain: target
            )
        } catch {
            throw .internalError("\(error)")
        }

        guard let sibling = siblings.first(where: { $0.derivationPath == currentAccount.derivationPath }) else {
            // Dapps often swallow the 4902, so tell the user what happened.
            let message = target.isCustomEVM
                ? String(localized: .ethereumDappChainIdNotFound(context.origin, Int(targetChainId)))
                : String(localized: .ethereumDappChainNotFound(context.origin, target.displayName))

            await context.approving.reportFailure(message)

            throw .chainNotFound
        }

        await context.session.setActiveAccount(sibling)
        return .null
    }
}

// MARK: - Message signing

private extension EthereumDappProvider {
    func personalSign(params: JSONValue, context: DappRequestContext) async throws(DappError) -> JSONValue {
        // The wire convention (matching geth/Anvil's own `personal_sign`)
        // is `[message, address]` — message first, reversed from most
        // other methods' `[address, ...]` shape.
        guard
            let messageHex = params[0]?.stringValue,
            let addressString = params[1]?.stringValue,
            let messageData = decodeHexData(messageHex)
        else {
            throw .invalidParams("personal_sign expects [message, address]")
        }

        let account = try await authorizedAccount(matching: addressString, context: context)
        let preview = DappMessagePreview.ethereumPersonal(messageData)

        let result = await context.session.withExclusiveApproval {
            await context.approving.approve(
                .signMessage(origin: context.origin, namespace: .ethereum, account: account, preview: preview)
            )
        }

        Logger.verbose("Eth personal_sign approval: \(result)")

        guard case .approved = result else {
            throw .userRejected
        }

        try await context.authorize(.ethereum, account: account)
        let signature = try await context.signingService.signMessage(.ethereumPersonal(messageData), account: account)
        Logger.verbose("Eth personal_sign signature: \(signature.hexEncoded)")
        return .string(signature.hexEncoded)
    }

    func signTypedData(params: JSONValue, context: DappRequestContext) async throws(DappError) -> JSONValue {
        guard let addressString = params[0]?.stringValue, let payload = params[1] else {
            throw .invalidParams("eth_signTypedData_v4 expects [address, typedData]")
        }

        let account = try await authorizedAccount(matching: addressString, context: context)

        // Some dapps pass the typed-data payload JSON-stringified rather
        // than as a plain object.
        let typedData: JSONValue
        if let raw = payload.stringValue {
            guard let data = raw.data(using: .utf8), let parsed = try? JSONValue(data: data) else {
                throw .invalidParams("eth_signTypedData_v4 payload must be JSON")
            }

            typedData = parsed
        } else {
            typedData = payload
        }

        guard
            let primaryType = typedData["primaryType"]?.stringValue,
            let domain = typedData["domain"],
            let message = typedData["message"],
            let types = typedData["types"]
        else {
            throw .invalidParams("eth_signTypedData_v4 payload is missing primaryType/domain/message/types")
        }

        let summary = EthereumTypedDataSummary(
            primaryType: primaryType,
            domainJSON: jsonString(domain),
            messageJSON: jsonString(message),
            typesJSON: jsonString(types)
        )

        let preview = DappMessagePreview.ethereumTypedData(summary)

        let result = await context.session.withExclusiveApproval {
            await context.approving.approve(
                .signMessage(origin: context.origin, namespace: .ethereum, account: account, preview: preview)
            )
        }

        Logger.verbose("Eth signTypedData approval: \(result)")

        guard case .approved = result else {
            throw .userRejected
        }

        try await context.authorize(.ethereum, account: account)
        let signature = try await context.signingService.signMessage(
            .ethereumTypedData(json: jsonString(typedData)),
            account: account
        )

        Logger.verbose("Eth signTypedData signature: \(signature.hexEncoded)")
        return .string(signature.hexEncoded)
    }
}

// MARK: - Sending a transaction

private extension EthereumDappProvider {
    func sendTransaction(params: JSONValue, context: DappRequestContext) async throws(DappError) -> JSONValue {
        guard let txJSON = params[0] else {
            throw .invalidParams("eth_sendTransaction expects [tx] with a from address")
        }

        let request = try EthereumTransactionRequest(txJSON)
        let account = try await authorizedAccount(matching: request.from, context: context)

        Logger.verbose("Eth sendTransaction: to \(request.toString ?? "nil") value \(request.value) from \(account.address)")

        let estimate: (gasLimit: BigUInt, rates: EthereumFeeRates)
        do {
            estimate = try await feeEstimationService.estimateCall(
                to: request.to, value: request.value, data: request.data, gasLimit: request.gasLimit, account: account
            )
        } catch {
            throw .internalError("\(error)")
        }

        // Dapp overrides are merged in before the prompt, so the sheet
        // shows exactly what gets signed.
        let (maxFee, maxPriorityFee) = request.feeCaps(rates: estimate.rates)
        let fees = feeEstimationService.ethereumFees(
            rates: estimate.rates, gasLimit: estimate.gasLimit, maxFee: maxFee, maxPriorityFee: maxPriorityFee
        )

        let call = EthereumCallPreview(
            to: request.toString,
            value: request.value,
            data: request.data,
            gasLimit: estimate.gasLimit,
            hasDappFeeOverrides: request.hasFeeOverrides
        )

        let approval = await context.session.withExclusiveApproval {
            await context.approving.approve(
                .sendTransaction(
                    origin: context.origin, namespace: .ethereum, account: account, preview: .ethereum(call, fees)
                )
            )
        }

        Logger.verbose("Eth sendTransaction approval: \(approval)")

        let options = [try Self.feeOverride(approval: approval, previewFees: fees, gasLimit: estimate.gasLimit)]

        do {
            let hash = try await broadcast(
                sender: account, to: request.to, value: request.value, data: request.data, options: options,
                authorize: { try await context.authorize(.ethereum, account: account) }
            )

            Logger.verbose("Eth sendTransaction broadcast: \(hash)")
            return hash
        } catch {
            Logger.verbose("Eth sendTransaction failed: \(error)")
            throw .internalError("\(error)")
        }
    }

    func broadcast(
        sender account: Account,
        to: EthereumAddress?,
        value: BigUInt,
        data: Data,
        options: [BlockchainTransactionBuilderOptions],
        authorize: (() async throws -> Void)? = nil
    ) async throws -> JSONValue {
        let client = try clientProvider.ethereumClient(for: account)
        let builder = EthereumTransactionBuilder(client: client)
        let sender = try EthereumAddress(string: account.address)
        let txBytes = try await builder.buildCall(sender: sender, to: to, value: value, data: data, options: options)
        Logger.verbose("Eth broadcast: built \(txBytes.count) bytes, signing")
        try await authorize?()
        let signature = try await transactionService.signTransaction(txBytes, account: account)
        Logger.verbose("Eth broadcast: signed, sending")
        let hash = try await transactionService.sendTransaction(txBytes, signature, account: account)
        return .string(hash)
    }
}

// MARK: - Read-only passthrough

private extension EthereumDappProvider {
    func passthrough(
        method: String, params: JSONValue, context: DappRequestContext
    ) async throws(DappError) -> JSONValue {
        guard let account = await context.session.selectedAccount(.ethereum) else {
            throw .disconnected
        }

        do {
            let client = try clientProvider.ethereumClient(for: account)
            let paramsData = try params.encoded()
            let resultData = try await client.request(method: method, params: paramsData)
            return try JSONValue(data: resultData)
        } catch {
            throw .internalError("\(error)")
        }
    }
} // swiftlint:disable:this file_length
