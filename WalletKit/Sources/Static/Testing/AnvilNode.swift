#if os(macOS)

import BigInt
import Foundation

/// An error raised when the local Anvil test node cannot be started or queried.
public struct AnvilLaunchError: Error, CustomStringConvertible {
    public let description: String

    public init(description: String) {
        self.description = description
    }
}

/// The subset of an Ethereum transaction receipt needed by local integration tests.
public struct TransactionReceipt: Decodable {
    public let status: String
    public let gasUsed: String
    public let effectiveGasPrice: String?
    public let contractAddress: String?
}

/// A local Foundry Anvil node used by integration tests.
public final class AnvilNode {
    public let endpoint: URL
    public let chainId: UInt64 = 31_337

    private let process: Process
    private let rpc: JSONRPCClient

    private init(process: Process, endpoint: URL) {
        self.process = process
        self.endpoint = endpoint
        rpc = JSONRPCClient(endpoint: endpoint)
    }

    /// Launches Anvil through the repository's mise-managed Foundry tool.
    public static func start(
        port: UInt16 = 8547,
        workingDirectory: URL? = nil
    ) async throws -> AnvilNode {
        let misePath = NSHomeDirectory() + "/.local/bin/mise"
        guard FileManager.default.fileExists(atPath: misePath) else {
            throw AnvilLaunchError(
                description: "mise not found at \(misePath) — this repo's other tooling requires it too"
            )
        }

        let sourceRoot = workingDirectory?.path
            ?? ProcessInfo.processInfo.environment["SRCROOT"]
            ?? FileManager.default.currentDirectoryPath
        let process = Process()
        process.executableURL = URL(fileURLWithPath: misePath)
        process.currentDirectoryURL = URL(fileURLWithPath: sourceRoot)
        process.arguments = [
            "-C", sourceRoot, "x", "foundry", "--",
            "anvil", "--port", String(port), "--chain-id", "31337"
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            throw AnvilLaunchError(
                description: "failed to launch mise at \(misePath): \(error.localizedDescription)"
            )
        }

        let endpoint = URL(string: "http://127.0.0.1:\(port)")!
        let node = AnvilNode(process: process, endpoint: endpoint)
        try await node.waitUntilReady()
        return node
    }

    public func stop() {
        process.terminate()
    }

    deinit {
        process.terminate()
    }

    private func waitUntilReady() async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(30))
        while ContinuousClock.now < deadline {
            // swiftlint:disable:next unused_optional_binding
            if let _: String = try? await rpc.call(method: "eth_blockNumber", params: [String]()) {
                return
            }
            try? await Task.sleep(for: .milliseconds(200))
        }

        throw AnvilLaunchError(description: "anvil never became ready on \(endpoint) within 60s")
    }

    /// Sets an account's native-token balance using Anvil's cheat-code RPC method.
    public func setBalance(_ address: EthereumAddress, wei: BigUInt) async throws {
        let _: Bool? = try? await rpc.call(
            method: "anvil_setBalance",
            params: [address.string, "0x" + String(wei, radix: 16)]
        )

        let actual = try await nativeBalance(of: address)
        guard actual == wei else {
            throw AnvilLaunchError(
                description: "anvil_setBalance(\(address.string), \(wei)) didn't take effect — balance is \(actual)"
            )
        }
    }

    /// Reads an account's native-token balance.
    public func nativeBalance(of address: EthereumAddress) async throws -> BigUInt {
        let hex: String = try await rpc.call(
            method: "eth_getBalance",
            params: [address.string, "latest"]
        )
        let body = hex.hasPrefix("0x") ? String(hex.dropFirst(2)) : hex
        guard let balance = BigUInt(body, radix: 16) else {
            throw BlockchainClientError.decodingFailed(reason: "invalid quantity hex: \(hex)")
        }
        return balance
    }

    public func transactionCount(of address: EthereumAddress) async throws -> BigUInt {
        let hex: String = try await rpc.call(
            method: "eth_getTransactionCount",
            params: [address.string, "pending"]
        )
        let body = hex.hasPrefix("0x") ? String(hex.dropFirst(2)) : hex
        guard let count = BigUInt(body, radix: 16) else {
            throw BlockchainClientError.decodingFailed(reason: "invalid quantity hex: \(hex)")
        }
        return count
    }

    public func gasPrice() async throws -> BigUInt {
        let hex: String = try await rpc.call(method: "eth_gasPrice", params: [String]())
        let body = hex.hasPrefix("0x") ? String(hex.dropFirst(2)) : hex
        guard let price = BigUInt(body, radix: 16) else {
            throw BlockchainClientError.decodingFailed(reason: "invalid quantity hex: \(hex)")
        }
        return price
    }

    /// Polls until Anvil returns a receipt for the transaction.
    public func waitForReceipt(_ transactionHash: String) async throws -> TransactionReceipt {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while ContinuousClock.now < deadline {
            if let receipt: TransactionReceipt = try? await rpc.call(
                method: "eth_getTransactionReceipt",
                params: [transactionHash]
            ) {
                return receipt
            }
            try? await Task.sleep(for: .milliseconds(100))
        }

        throw AnvilLaunchError(description: "no receipt for \(transactionHash) within 10s")
    }
}

#endif
