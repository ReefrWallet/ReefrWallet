//
//  WalletConnectMethodAdapter.swift
//  Reefr Wallet
//
//  Created by Andrey Yurkevich on 17.10.26.
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import Foundation
import WalletKit

/// Translates WalletConnect chain-RPC methods to and from the
/// Wallet Standard/EIP-1193-shaped requests the injected-provider
/// ``DappProvider``s answer, so both transports share one signing path.
enum WalletConnectMethodAdapter {
    struct Adapted: Equatable {
        let method: String
        let params: JSONValue
    }

    static func adaptRequest(
        method: String, params: JSONValue, namespace: DappNamespace, account: Account
    ) throws(DappError) -> Adapted {
        switch namespace {
        case .aptos:
            return try aptos(method: method, params: params, account: account)
        case .ethereum:
            guard WalletConnectChain.methods[.ethereum]?.contains(method) == true else {
                throw .unsupportedMethod
            }

            return Adapted(method: method, params: params)
        case .solana:
            return try solana(method: method, params: params, account: account)
        case .sui:
            return try sui(method: method, params: params, account: account)
        case .tron:
            return try tron(method: method, params: params)
        }
    }

    static func adaptResult(
        method: String, result: JSONValue, namespace: DappNamespace, request: JSONValue
    ) throws(DappError) -> JSONValue {
        switch (namespace, method) {
        case (.solana, "solana_signMessage"), (.solana, "solana_signAndSendTransaction"):
            guard
                let signature = result["signature"]?.stringValue.flatMap({ Data(base64Encoded: $0) })
            else {
                throw .internalError("missing signature")
            }

            return .object(["signature": .string(Base58.encode(signature))])
        case (.solana, "solana_signTransaction"):
            guard
                let transaction = result["signedTransaction"]?.stringValue,
                let bytes = Data(base64Encoded: transaction),
                let signature = firstSignature(of: bytes)
            else {
                throw .internalError("missing signed transaction")
            }

            return .object(["signature": .string(Base58.encode(signature)), "transaction": .string(transaction)])
        case (.sui, "sui_signTransaction"):
            guard let signature = result["signature"], let bytes = result["bytes"] else {
                throw .internalError("missing signature")
            }

            return .object(["signature": signature, "transactionBytes": bytes])
        case (.tron, "tron_signTransaction"):
            guard
                let signature = result["signature"],
                var transaction = (request["transaction"]?["transaction"] ?? request["transaction"])?.objectValue
            else {
                throw .internalError("missing signature")
            }

            transaction["signature"] = .array([signature])
            return .object(transaction)
        default:
            return result
        }
    }

    // MARK: Helpers

    private static func firstSignature(of wireTransaction: Data) -> Data? {
        // Short-vec length prefix: one byte for up to 127 signatures.
        guard let count = wireTransaction.first, count > 0, count < 128, wireTransaction.count >= 65 else {
            return nil
        }

        return wireTransaction.subdata(in: 1 ..< 65)
    }

    private static func account(_ address: String) -> JSONValue {
        .object(["address": .string(address)])
    }

    private static func aptos(method: String, params: JSONValue, account: Account) throws(DappError) -> Adapted {
        switch method {
        case "aptos_signMessage":
            guard var object = params.objectValue else {
                throw .invalidParams("aptos_signMessage expects an object")
            }

            object["account"] = Self.account(account.address)
            return Adapted(method: "signMessage", params: .object(object))
        case "aptos_signTransaction":
            guard var object = params.objectValue else {
                throw .invalidParams("aptos_signTransaction expects an object")
            }

            object["account"] = Self.account(account.address)
            return Adapted(method: "signTransaction", params: .object(object))
        default:
            throw .unsupportedMethod
        }
    }

    private static func solana(method: String, params: JSONValue, account: Account) throws(DappError) -> Adapted {
        let chain: String? = if case let .solana(network) = account.blockchain {
            switch network {
            case .devnet: "solana:devnet"
            case .mainnet: "solana:mainnet"
            case .testnet: "solana:testnet"
            }
        } else {
            nil
        }

        switch method {
        case "solana_signMessage":
            guard let message = params["message"]?.stringValue, let bytes = try? Base58.decode(message) else {
                throw .invalidParams("solana_signMessage expects {pubkey, message}")
            }

            return Adapted(
                method: "signMessage",
                params: .object([
                    "message": .string(bytes.base64EncodedString()),
                    "account": Self.account(account.address)
                ])
            )

        case "solana_signTransaction", "solana_signAndSendTransaction":
            guard let transaction = params["transaction"]?.stringValue, Data(base64Encoded: transaction) != nil else {
                throw .invalidParams("\(method) expects {transaction: <base64>}")
            }

            var object: [String: JSONValue] = [
                "transaction": .string(transaction),
                "account": Self.account(account.address)
            ]

            if let chain {
                object["chain"] = .string(chain)
            }

            if method == "solana_signAndSendTransaction", let options = params["sendOptions"] {
                object["options"] = options
            }

            return Adapted(
                method: method == "solana_signTransaction" ? "signTransaction" : "signAndSendTransaction",
                params: .object(object)
            )

        default:
            throw .unsupportedMethod
        }
    }

    private static func sui(method: String, params: JSONValue, account: Account) throws(DappError) -> Adapted {
        switch method {
        case "sui_signPersonalMessage":
            guard let message = params["message"]?.stringValue else {
                throw .invalidParams("sui_signPersonalMessage expects {message, address}")
            }

            return Adapted(
                method: "signPersonalMessage",
                params: .object(["message": .string(message), "account": Self.account(account.address)])
            )

        case "sui_signTransaction", "sui_signAndExecuteTransaction":
            guard let transaction = params["transaction"]?.stringValue ?? params["transactionBytes"]?.stringValue else {
                throw .invalidParams("\(method) expects {transaction: <base64>, address}")
            }

            var object: [String: JSONValue] = [
                "transactionBytes": .string(transaction),
                "account": Self.account(account.address)
            ]

            if let chain = WalletConnectChain.caip2(for: account.blockchain) {
                object["chain"] = .string(chain)
            }

            return Adapted(
                method: method == "sui_signTransaction" ? "signTransaction" : "signAndExecuteTransaction",
                params: .object(object)
            )

        default:
            throw .unsupportedMethod
        }
    }

    private static func tron(method: String, params: JSONValue) throws(DappError) -> Adapted {
        switch method {
        case "tron_signMessage":
            guard let message = params["message"]?.stringValue else {
                throw .invalidParams("tron_signMessage expects {message, address}")
            }

            return Adapted(
                method: "signMessage",
                params: .object(["message": .string(Data(message.utf8).map { String(format: "%02x", $0) }.joined())])
            )

        case "tron_signTransaction":
            // WalletConnect nests the TronWeb transaction one level deeper.
            guard let transaction = params["transaction"]?["transaction"] ?? params["transaction"] else {
                throw .invalidParams("tron_signTransaction expects {transaction: {transaction}}")
            }

            return Adapted(method: "signTransaction", params: .object(["transaction": transaction]))
        default:
            throw .unsupportedMethod
        }
    }
}
