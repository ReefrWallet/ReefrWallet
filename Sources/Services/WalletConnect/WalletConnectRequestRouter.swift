//
//  WalletConnectRequestRouter.swift
//  Reefr Wallet
//
//  Created by Andrey Yurkevich on 17.10.26.
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import Foundation
import WalletKit

/// Runs one WalletConnect request through the shared ``DappProvider``
/// pipeline (approval prompt, signing) and shapes the response.
@MainActor
struct WalletConnectRequestRouter {
    let approving: any DappApproving
    let providers: [DappNamespace: any DappProvider]
    let signingService: DappSigningService

    init(
        approving: any DappApproving,
        signingService: DappSigningService,
        providers: [any DappProvider] = [
            AptosDappProvider(), EthereumDappProvider(), SolanaDappProvider(), SuiDappProvider(), TronDappProvider()
        ]
    ) {
        self.approving = approving
        self.providers = Dictionary(uniqueKeysWithValues: providers.map { (type(of: $0).namespace, $0) })
        self.signingService = signingService
    }

    /// `account` is the one the user approved for the request's chain;
    /// `session` holds the grant for the dapp's origin.
    func handle(
        method: String, params: Data, chainId: String, account: Account, origin: String, session: DappSession
    ) async -> Result<Data, WalletConnectRPCError> {
        Logger.verbose("WC route: \(method) chain: \(chainId) account: \(account.address) origin: \(origin)")

        guard
            let namespace = WalletConnectChain.dappNamespace(caip2: chainId),
            namespace.matches(account.blockchain),
            let provider = providers[namespace]
        else {
            Logger.verbose("WC route: chain not found for \(chainId), account blockchain: \(account.blockchain)")
            return .failure(Self.rpcError(.chainNotFound))
        }

        do {
            let requestParams = try JSONValue(data: params)
            let adapted = try WalletConnectMethodAdapter.adaptRequest(
                method: method, params: requestParams, namespace: namespace, account: account
            )

            Logger.verbose("WC route: adapted to \(adapted.method)")

            // The proposal approval is the user's consent to this account.
            await session.replaceActiveAccount(account)
            guard await session.grantPermission(namespace, origin: origin, account: account) else {
                throw DappError.unauthorized
            }

            let context = DappRequestContext(
                origin: origin, session: session, approving: approving, signingService: signingService
            )

            let result = try await DappRequestScope.run(approving: approving) {
                try await provider.handle(method: adapted.method, params: adapted.params, context: context)
            }

            Logger.verbose("WC route: provider result \(result)")

            let response = try WalletConnectMethodAdapter.adaptResult(
                method: method, result: result, namespace: namespace, request: requestParams
            )

            return .success(try JSONEncoder().encode(response))
        } catch let error as DappError {
            Logger.verbose("WC route: DappError \(error)")
            return .failure(Self.rpcError(error))
        } catch {
            Logger.verbose("WC route: error \(error)")
            return .failure(WalletConnectRPCError(code: -32603, message: "\(error)"))
        }
    }

    static func rpcError(_ error: DappError) -> WalletConnectRPCError {
        switch error {
        case .chainNotFound: WalletConnectRPCError(code: 4902, message: error.localizedDescription)
        case .disconnected: WalletConnectRPCError(code: 4900, message: error.localizedDescription)
        case .internalError: WalletConnectRPCError(code: -32603, message: error.localizedDescription)
        case .invalidParams: WalletConnectRPCError(code: -32602, message: error.localizedDescription)
        case .unauthorized: WalletConnectRPCError(code: 4100, message: error.localizedDescription)
        case .unsupportedMethod: WalletConnectRPCError(code: 4200, message: error.localizedDescription)
        case .userRejected: WalletConnectRPCError(code: 4001, message: error.localizedDescription)
        }
    }
}
