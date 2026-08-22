//
//  SuiGRPCClient.swift
//  WalletKit
//
//  Created by Andrey Yurkevich on 17/08/2026.
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import Foundation
import GRPCCore
import GRPCNIOTransportHTTP2Posix
import WalletKitGRPC

/// A client for Sui's gRPC full-node API — coin balance and broadcasting
/// an already-signed transaction. Pairs with ``SuiPKeySigner``, which
/// produces the raw BCS transaction bytes and signature ``broadcast(transactionData:signature:)``
/// sends; this client builds no transactions of its own.
///
/// Sui's node API is gRPC (`sui.rpc.v2`, vendored as the
/// `Sources/gRPC/sui-rpc-api-v2` submodule and compiled by `make sui-grpc`
/// into `WalletKitGRPC`), unlike Ethereum's plain JSON-RPC over
/// `URLSession` (``EthereumRPCClient``/``JSONRPCClient``).
///
/// - Note: Each call opens a fresh connection for the duration of that
///   one RPC (via `withGRPCClient`) rather than holding a long-lived
///   connection open across calls — simple and correct, at the cost of
///   not reusing a connection between repeated calls from the same
///   client instance.
public struct SuiGRPCClient {
    private let host: String
    private let port: Int
    private let useTLS: Bool

    /// Creates a client for the gRPC full node at `host`.
    ///
    /// - Parameters:
    ///   - host: The full node's hostname (or IP address).
    ///   - port: The gRPC port. Defaults to `443`.
    ///   - useTLS: Whether to use TLS. Defaults to `true`.
    public init(host: String, port: Int = 443, useTLS: Bool = true) {
        self.host = host
        self.port = port
        self.useTLS = useTLS
    }

    /// Reads `address`'s balance of `coinType` — any Sui coin, not just
    /// native SUI.
    ///
    /// - Parameters:
    ///   - address: The account to read the balance of.
    ///   - coinType: The coin type, e.g. `"0x2::sui::SUI"`.
    /// - Returns: The balance, in the coin's smallest unit.
    /// - Throws: ``BlockchainClientError`` on a transport, RPC, or
    ///   decoding failure.
    public func coinBalance(of address: SuiAddress, coinType: String = "0x2::sui::SUI") async throws -> UInt64 {
        try await withStateServiceClient { client in
            let request = Sui_Rpc_V2_GetBalanceRequest.with {
                $0.owner = address.string
                $0.coinType = coinType
            }
            let response = try await client.getBalance(request: ClientRequest(message: request))
            return response.balance.balance
        }
    }

    public func listAllBalances(of address: SuiAddress) async throws -> [Sui_Rpc_V2_Balance] {
        try await withStateServiceClient { client in
            let request = Sui_Rpc_V2_ListBalancesRequest.with {
                $0.owner = address.string
            }
            let response = try await client.listBalances(request: ClientRequest(message: request))
            return response.balances
        }
    }

    /// Reads `coinType`'s metadata — name, symbol, and decimals.
    ///
    /// - Parameter coinType: The coin type, e.g. `"0x2::sui::SUI"`.
    /// - Returns: The coin's metadata.
    /// - Throws: ``BlockchainClientError`` on a transport, RPC, or
    ///   decoding failure.
    public func coinInfo(coinType: String = "0x2::sui::SUI") async throws -> TokenInfo {
        try await withStateServiceClient { client in
            let request = Sui_Rpc_V2_GetCoinInfoRequest.with {
                $0.coinType = coinType
            }
            let response = try await client.getCoinInfo(request: ClientRequest(message: request))
            return TokenInfo(
                name: response.metadata.name,
                symbol: response.metadata.symbol,
                decimals: UInt8(response.metadata.decimals)
            )
        }
    }

    /// Reads `address`'s native SUI balance —
    /// ``coinBalance(of:coinType:)`` with the default `"0x2::sui::SUI"`
    /// coin type.
    ///
    /// - Parameter address: The account to read the balance of.
    /// - Returns: The balance, in MIST (SUI's smallest unit).
    /// - Throws: ``BlockchainClientError`` on a transport, RPC, or
    ///   decoding failure.
    public func nativeBalance(of address: SuiAddress) async throws -> UInt64 {
        try await coinBalance(of: address)
    }

    /// Lists objects owned by `owner`.
    ///
    /// - Parameter owner: The account to list owned objects for.
    /// - Returns: The owner's objects (a single page — up to the node's
    ///   default page size).
    /// - Throws: ``BlockchainClientError`` on a transport, RPC, or
    ///   decoding failure.
    public func getOwnedObjects(_ owner: SuiAddress) async throws -> [Sui_Rpc_V2_Object] {
        try await withStateServiceClient { client in
            let request = Sui_Rpc_V2_ListOwnedObjectsRequest.with {
                $0.owner = owner.string
            }
            let response = try await client.listOwnedObjects(request: ClientRequest(message: request))
            return response.objects
        }
    }

    /// Broadcasts an already-signed transaction.
    ///
    /// - Parameters:
    ///   - transactionData: The raw BCS-encoded `TransactionData` bytes
    ///     that were signed, e.g. the bytes passed to
    ///     ``SuiPKeySigner/sign(transaction:)``.
    ///   - signature: The serialized signature over `transactionData`,
    ///     e.g. from ``SuiPKeySigner/sign(transaction:)``.
    /// - Returns: The executed transaction's digest.
    /// - Throws: ``BlockchainClientError`` on a transport, RPC, or
    ///   decoding failure.
    public func broadcast(transactionData: Data, signature: Data) async throws -> String {
        try await withTransactionExecutionServiceClient { client in
            let request = Sui_Rpc_V2_ExecuteTransactionRequest.with {
                $0.transaction = Sui_Rpc_V2_Transaction.with {
                    $0.bcs = Sui_Rpc_V2_Bcs.with { $0.value = transactionData }
                }
                $0.signatures = [
                    Sui_Rpc_V2_UserSignature.with {
                        $0.bcs = Sui_Rpc_V2_Bcs.with { $0.value = signature }
                    }
                ]
                // The default read mask (`effects.status,checkpoint`) omits
                // `digest` entirely, so without this the returned digest is
                // empty and unusable for a follow-up `GetTransaction` call.
                $0.readMask.paths = ["digest"]
            }
            let response = try await client.executeTransaction(request: ClientRequest(message: request))
            return response.transaction.digest
        }
    }

    private func transport() throws -> HTTP2ClientTransport.Posix {
        do {
            return try HTTP2ClientTransport.Posix(
                target: .dns(host: host, port: port),
                transportSecurity: useTLS ? .tls : .plaintext
            )
        } catch {
            throw BlockchainClientError.transportError(reason: error.localizedDescription)
        }
    }

    private func withStateServiceClient<Result: Sendable>(
        _ body: @escaping (Sui_Rpc_V2_StateService.Client<HTTP2ClientTransport.Posix>) async throws -> Result
    ) async throws -> Result {
        try await withRemappedErrors {
            try await withGRPCClient(transport: try transport()) { grpcClient in
                try await body(Sui_Rpc_V2_StateService.Client(wrapping: grpcClient))
            }
        }
    }

    private func withTransactionExecutionServiceClient<Result: Sendable>(
        _ body: @escaping (Sui_Rpc_V2_TransactionExecutionService.Client<HTTP2ClientTransport.Posix>) async throws
            -> Result
    ) async throws -> Result {
        try await withRemappedErrors {
            try await withGRPCClient(transport: try transport()) { grpcClient in
                try await body(Sui_Rpc_V2_TransactionExecutionService.Client(wrapping: grpcClient))
            }
        }
    }
}

/// Runs `body`, translating a thrown `RPCError` (a gRPC `Status` the node
/// returned) into ``BlockchainClientError/rpcError(code:message:)``.
/// Already-thrown `BlockchainClientError`s (e.g. from `transport()`) pass
/// through unchanged.
private func withRemappedErrors<Result: Sendable>(_ body: () async throws -> Result) async throws -> Result {
    do {
        return try await body()
    } catch let error as BlockchainClientError {
        throw error
    } catch let error as RPCError {
        throw BlockchainClientError.rpcError(code: error.code.rawValue, message: error.message)
    } catch {
        throw BlockchainClientError.transportError(reason: error.localizedDescription)
    }
}
