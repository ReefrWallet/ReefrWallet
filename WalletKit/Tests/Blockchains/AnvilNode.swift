// Process lifecycle + the handful of JSON-RPC/cheat-code calls
// EthereumAnvilTests.swift needs beyond what EthereumRPCClient exposes
// publicly (nonce, gas price, receipts, Anvil's own anvil_setBalance) —
// built on WalletKit's own internal JSONRPCClient, reachable here via
// @testable import exactly like EthereumRPCClientTests.swift already does.
//
// anvil isn't installed anywhere on this machine by default, so it's run
// via `mise x foundry -- anvil ...`, invoked through mise's own absolute
// path rather than relying on shims being on the test host process's PATH
// (an Xcode.app-launched process doesn't reliably inherit a dev shell's
// PATH) — the same pattern WalletKit/Project.swift's build-phase scripts
// already use to invoke mise-managed tools (e.g. `$HOME/.local/bin/mise
// -C $SRCROOT x swiftlint -- swiftlint ...`). `foundry` is pinned in
// mise.toml, so this auto-installs on first use exactly like `tuist`/
// `swiftlint` already do — no manual setup step, no `withKnownIssue`
// gating: if `mise`/`foundry` can't be found or the node never comes up,
// this throws a clear, actionable error and the test fails loudly.

import BigInt
import Foundation
import Testing
@testable import WalletKit

struct AnvilLaunchError: Error, CustomStringConvertible {
    let description: String
}

struct TransactionReceipt: Decodable {
    let status: String
    let gasUsed: String
    let effectiveGasPrice: String?
    let contractAddress: String?
}

final class AnvilNode {
    let endpoint: URL
    let chainId: UInt64 = 31_337

    private let process: Process
    private let rpc: JSONRPCClient

    private init(process: Process, endpoint: URL) {
        self.process = process
        self.endpoint = endpoint
        rpc = JSONRPCClient(endpoint: endpoint)
    }

    /// Launches `anvil` via `mise x foundry -- anvil` and waits until it's
    /// actually serving requests.
    ///
    /// - Throws: `AnvilLaunchError` if `mise` itself can't be found/run, or
    ///   if the node never becomes ready within the timeout — a generous
    ///   one, since a first-ever, not-yet-cached `foundry` install has to
    ///   download it before `anvil` can even start.
    static func start(port: UInt16 = 8547) async throws -> AnvilNode {
        let misePath = NSHomeDirectory() + "/.local/bin/mise"
        guard FileManager.default.fileExists(atPath: misePath) else {
            throw AnvilLaunchError(
                description: "mise not found at \(misePath) — this repo's other tooling requires it too"
            )
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: misePath)
        process.arguments = [
            "x", "foundry", "--",
            "anvil", "--port", String(port), "--chain-id", "31337", "--silent"
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            throw AnvilLaunchError(description: "failed to launch mise at \(misePath): \(error.localizedDescription)")
        }

        let endpoint = URL(string: "http://127.0.0.1:\(port)")!
        let node = AnvilNode(process: process, endpoint: endpoint)
        try await node.waitUntilReady()
        return node
    }

    func stop() {
        process.terminate()
    }

    deinit {
        process.terminate()
    }

    private func waitUntilReady() async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(60))
        while ContinuousClock.now < deadline {
            if let _: String = try? await rpc.call(method: "eth_blockNumber", params: [String]()) {
                return
            }
            try? await Task.sleep(for: .milliseconds(200))
        }
        throw AnvilLaunchError(description: "anvil never became ready on \(endpoint) within 60s")
    }

    // MARK: - Cheat codes / extra RPC methods

    /// Sets `address`'s native balance via Anvil's `anvil_setBalance` cheat
    /// code, then reads it back to confirm it actually took effect.
    ///
    /// - Throws: `AnvilLaunchError` if the readback doesn't match `wei`.
    ///   The cheat call's own response isn't checked directly: Anvil
    ///   returns `true` on some versions and `null` on others, and
    ///   `JSONRPCClient` treats an explicit `null` result the same as a
    ///   missing one (an error) — so trusting the response shape here
    ///   would either reject a legitimate success or accept a real
    ///   failure, depending on the installed Anvil version. Reading the
    ///   balance back sidesteps that ambiguity entirely.
    func setBalance(_ address: EthereumAddress, wei: BigUInt) async throws {
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

    private func nativeBalance(of address: EthereumAddress) async throws -> BigUInt {
        let hex: String = try await rpc.call(method: "eth_getBalance", params: [address.string, "latest"])
        let body = hex.hasPrefix("0x") ? String(hex.dropFirst(2)) : hex
        guard let balance = BigUInt(body, radix: 16) else {
            throw BlockchainClientError.decodingFailed(reason: "invalid quantity hex: \(hex)")
        }
        return balance
    }

    func transactionCount(of address: EthereumAddress) async throws -> BigUInt {
        let hex: String = try await rpc.call(method: "eth_getTransactionCount", params: [address.string, "pending"])
        let body = hex.hasPrefix("0x") ? String(hex.dropFirst(2)) : hex
        guard let count = BigUInt(body, radix: 16) else {
            throw BlockchainClientError.decodingFailed(reason: "invalid quantity hex: \(hex)")
        }
        return count
    }

    func gasPrice() async throws -> BigUInt {
        let hex: String = try await rpc.call(method: "eth_gasPrice", params: [String]())
        let body = hex.hasPrefix("0x") ? String(hex.dropFirst(2)) : hex
        guard let price = BigUInt(body, radix: 16) else {
            throw BlockchainClientError.decodingFailed(reason: "invalid quantity hex: \(hex)")
        }
        return price
    }

    /// Polls `eth_getTransactionReceipt` until `transactionHash`'s receipt
    /// exists — Anvil auto-mines each submitted transaction into its own
    /// block instantly, so this normally resolves on the first or second
    /// poll.
    func waitForReceipt(_ transactionHash: String) async throws -> TransactionReceipt {
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
