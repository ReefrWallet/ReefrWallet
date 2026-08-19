// Process lifecycle + the gRPC/faucet calls SuiLocalnetTests.swift needs
// beyond what SuiGRPCClient exposes publicly (owned-coin lookup, reference
// gas price, transaction effects, faucet funding) — the Sui counterpart of
// AnvilNode.swift.
//
// `sui` isn't installed anywhere on this machine by default; it's pinned
// in mise.toml (`sui = "testnet-v1.77.2"`) and run via `mise x sui --
// sui ...`, invoked through mise's own absolute path for the same reason
// AnvilNode.swift gives: an Xcode.app-launched test process doesn't
// reliably inherit a dev shell's PATH. Unlike Anvil, more than one `sui`
// version can be installed side by side (this machine has both
// `testnet-latest` and the pinned `testnet-v1.77.2`), so the binary path
// is resolved once via `mise which sui` (config-anchored to this repo's
// mise.toml) rather than guessed.
//
// `sui start --force-regenesis` always writes its genesis/keystore/DB
// under `$HOME/.sui/sui_config` — there's no flag to redirect that when
// combined with `--force-regenesis` (`--network.config` explicitly
// rejects that combination, since it expects a directory `sui genesis`
// already populated). So `HOME` is overridden to a per-run temporary
// directory for the launched process only, which sandboxes the network's
// state without touching the invoking user's real `~/.sui`.
//
// No `withKnownIssue` gating, matching AnvilNode.swift/EthereumAnvilTests:
// if `mise`/`sui` can't be found/run, or the node never comes up, this
// throws a clear, actionable error and the test fails loudly.

import Foundation
import GRPCCore
import GRPCNIOTransportHTTP2Posix
import Testing
@testable import WalletKit
import WalletKitGRPC

struct SuiLaunchError: Error, CustomStringConvertible {
    let description: String
}

/// A `(objectId, version, digest)` reference to a specific version of an
/// on-chain object, decoded from a `ListOwnedObjects`/`GetTransaction`
/// response — the gRPC API's own `ObjectReference`, but with `digest`
/// already Base58-decoded to raw bytes as ``SuiObjectReference`` (the
/// `TransactionData` field it feeds) expects.
struct SuiOwnedCoin {
    let reference: SuiObjectReference
    let balance: UInt64
}

/// Decodes a Base58 (Bitcoin-alphabet) string to raw bytes — the encoding
/// Sui's gRPC API uses for object/transaction digests, unlike the `0x`-hex
/// everywhere else in this codebase.
private enum Base58 {
    private static let alphabet = Array("123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz")
    private static let indexByCharacter = Dictionary(uniqueKeysWithValues: alphabet.enumerated().map { ($1, $0) })

    static func decode(_ string: String) throws -> Data {
        var bytes: [Int] = [0]
        for character in string {
            guard let digit = indexByCharacter[character] else {
                throw SuiLaunchError(description: "'\(string)' is not valid Base58 (bad character '\(character)')")
            }
            var carry = digit
            for index in 0..<bytes.count {
                let value = bytes[index] * 58 + carry
                bytes[index] = value & 0xFF
                carry = value >> 8
            }
            while carry > 0 {
                bytes.append(carry & 0xFF)
                carry >>= 8
            }
        }
        let leadingZeros = string.prefix(while: { $0 == "1" }).count
        let significant = Data(bytes.reversed().map { UInt8($0) })
        return Data(repeating: 0, count: leadingZeros) + significant
    }
}

final class SuiNode {
    let rpcPort: UInt16
    private let faucetPort: UInt16
    private let process: Process
    private let workingDirectory: URL
    private let logHandle: FileHandle

    private init(process: Process, rpcPort: UInt16, faucetPort: UInt16, workingDirectory: URL, logHandle: FileHandle) {
        self.process = process
        self.rpcPort = rpcPort
        self.faucetPort = faucetPort
        self.workingDirectory = workingDirectory
        self.logHandle = logHandle
    }

    /// Launches a fresh local Sui network via `mise x sui -- sui start
    /// --force-regenesis --with-faucet`, and waits until it's actually
    /// producing checkpoints.
    ///
    /// - Throws: ``SuiLaunchError`` if `mise`/`sui` can't be found/run, or
    ///   if the node never becomes ready within the timeout — a generous
    ///   one, since a first-ever, not-yet-cached `sui` install has to
    ///   download it (~180 MB) before it can even start.
    static func start(rpcPort: UInt16 = 9010, faucetPort: UInt16 = 9133) async throws -> SuiNode {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Blockchains/
            .deletingLastPathComponent() // Tests/
            .deletingLastPathComponent() // WalletKit/

        let misePath = NSHomeDirectory() + "/.local/bin/mise"
        guard FileManager.default.fileExists(atPath: misePath) else {
            throw SuiLaunchError(
                description: "mise not found at \(misePath) — this repo's other tooling requires it too"
            )
        }

        let suiBinaryPath = try resolveSuiBinaryPath(misePath: misePath, repoRoot: repoRoot)

        let workingDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("sui-localnet-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workingDirectory, withIntermediateDirectories: true)

        let logURL = workingDirectory.appendingPathComponent("sui.log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        let logHandle = try FileHandle(forWritingTo: logURL)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: suiBinaryPath)
        process.arguments = [
            "start", "--force-regenesis",
            "--with-faucet=127.0.0.1:\(faucetPort)",
            "--fullnode-rpc-port", String(rpcPort),
            "--committee-size", "1",
            "-q"
        ]
        // `sui start --force-regenesis` always writes under
        // `$HOME/.sui/sui_config` — overriding HOME for just this process
        // sandboxes that without touching the real `~/.sui`.
        process.environment = ["HOME": workingDirectory.path]
        process.standardOutput = logHandle
        process.standardError = logHandle

        do {
            try process.run()
        } catch {
            throw SuiLaunchError(description: "failed to launch \(suiBinaryPath): \(error.localizedDescription)")
        }

        let node = SuiNode(
            process: process,
            rpcPort: rpcPort,
            faucetPort: faucetPort,
            workingDirectory: workingDirectory,
            logHandle: logHandle
        )
        try await node.waitUntilReady()
        return node
    }

    /// Resolves the pinned `sui` binary's absolute path via `mise which`,
    /// anchored to this repo's `mise.toml` (`-C repoRoot`) so the pinned
    /// `testnet-v1.77.2` is used even when another `sui` version is also
    /// installed. `mise x sui -- true` first, to trigger mise's own
    /// auto-install on first use — same as `AnvilNode`'s `mise x foundry`.
    private static func resolveSuiBinaryPath(misePath: String, repoRoot: URL) throws -> String {
        func run(_ arguments: [String]) throws -> String {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: misePath)
            process.arguments = arguments
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = Pipe()
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                throw SuiLaunchError(description: "\(misePath) \(arguments.joined(separator: " ")) failed")
            }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }

        _ = try run(["-C", repoRoot.path, "x", "sui", "--", "true"])
        return try run(["-C", repoRoot.path, "which", "sui"])
    }

    func stop() {
        process.terminate()
        process.waitUntilExit()
        try? logHandle.close()
        try? FileManager.default.removeItem(at: workingDirectory)
    }

    deinit {
        if process.isRunning {
            process.terminate()
        }
        try? FileManager.default.removeItem(at: workingDirectory)
    }

    private func client() -> SuiGRPCClient {
        SuiGRPCClient(host: "127.0.0.1", port: Int(rpcPort), useTLS: false)
    }

    private func waitUntilReady() async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(180))
        while ContinuousClock.now < deadline {
            if let height = try? await checkpointHeight(), height > 0 {
                return
            }
            try? await Task.sleep(for: .milliseconds(200))
        }
        let log = (try? String(contentsOf: workingDirectory.appendingPathComponent("sui.log"), encoding: .utf8))
            ?? "(no log)"
        throw SuiLaunchError(description: "sui never became ready within 180s. Log tail:\n\(log.suffix(2000))")
    }

    private func checkpointHeight() async throws -> UInt64 {
        try await withLedgerServiceClient { ledger in
            let response = try await ledger.getServiceInfo(
                request: ClientRequest(message: Sui_Rpc_V2_GetServiceInfoRequest())
            )
            return response.checkpointHeight
        }
    }

    /// Requests SUI from the local faucet for `address`, then polls
    /// ``SuiGRPCClient/nativeBalance(of:)`` until it's non-zero — sidesteps
    /// having to parse the faucet's response body, whose shape has drifted
    /// across `sui` versions (`/gas` vs. `/v1/gas`, `coins_sent` vs.
    /// `transferredGasObjects`), the same "read the result back instead of
    /// trusting the response" trick `AnvilNode.setBalance` uses for
    /// `anvil_setBalance`'s ambiguous return.
    func faucet(_ address: SuiAddress) async throws {
        var lastStatus = -1
        for path in ["/gas", "/v1/gas"] {
            let url = URL(string: "http://127.0.0.1:\(faucetPort)\(path)")!
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(FaucetRequest(recipient: address.string))

            guard let (_, response) = try? await URLSession.shared.data(for: request),
                  let httpResponse = response as? HTTPURLResponse else {
                continue
            }
            lastStatus = httpResponse.statusCode
            if (200..<300).contains(httpResponse.statusCode) {
                try await waitForNonZeroBalance(of: address)
                return
            }
        }
        throw SuiLaunchError(description: "faucet request for \(address.string) failed (tried /gas, /v1/gas; last HTTP status \(lastStatus))")
    }

    private struct FaucetRequest: Encodable {
        struct Recipient: Encodable {
            let recipient: String
        }
        let fixedAmountRequest: Recipient

        enum CodingKeys: String, CodingKey {
            case fixedAmountRequest = "FixedAmountRequest"
        }

        init(recipient: String) {
            fixedAmountRequest = Recipient(recipient: recipient)
        }
    }

    private func waitForNonZeroBalance(of address: SuiAddress) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(30))
        while ContinuousClock.now < deadline {
            if let balance = try? await client().nativeBalance(of: address), balance > 0 {
                return
            }
            try? await Task.sleep(for: .milliseconds(200))
        }
        throw SuiLaunchError(description: "faucet funding for \(address.string) didn't take effect within 30s")
    }

    /// The current epoch's reference gas price, for building a transaction.
    func referenceGasPrice() async throws -> UInt64 {
        try await withLedgerServiceClient { ledger in
            var request = Sui_Rpc_V2_GetEpochRequest()
            request.readMask.paths = ["reference_gas_price"]
            let response = try await ledger.getEpoch(request: ClientRequest(message: request))
            return response.epoch.referenceGasPrice
        }
    }

    /// `address`'s owned native-SUI coin objects, largest balance first.
    func suiCoins(of address: SuiAddress) async throws -> [SuiOwnedCoin] {
        try await withStateServiceClient { state in
            var request = Sui_Rpc_V2_ListOwnedObjectsRequest()
            request.owner = address.string
            request.objectType = "0x2::coin::Coin<0x2::sui::SUI>"
            request.readMask.paths = ["object_id", "version", "digest", "balance"]
            let response = try await state.listOwnedObjects(request: ClientRequest(message: request))
            return try response.objects.map { object in
                SuiOwnedCoin(
                    reference: SuiObjectReference(
                        objectId: try self.hexDecoded(object.objectID),
                        version: object.version,
                        digest: try Base58.decode(object.digest)
                    ),
                    balance: object.balance
                )
            }.sorted { $0.balance > $1.balance }
        }
    }

    /// The largest native-SUI coin `address` owns — used as the sole gas
    /// payment object for the split-and-transfer PTBs this suite builds.
    ///
    /// - Throws: ``SuiLaunchError`` if `address` owns no SUI coins.
    func largestSuiCoin(of address: SuiAddress) async throws -> SuiObjectReference {
        guard let largest = try await suiCoins(of: address).first else {
            throw SuiLaunchError(description: "\(address.string) owns no SUI coins")
        }
        return largest.reference
    }

    /// Polls `LedgerService.GetTransaction` for `digest`'s effects, until
    /// it lands in a checkpoint — the ``waitForReceipt(_:)`` analogue for
    /// `AnvilNode`, needed because a broadcast localnet transaction isn't
    /// necessarily final the instant `broadcast(transactionData:signature:)`
    /// returns.
    func waitForEffects(_ digest: String) async throws -> Sui_Rpc_V2_TransactionEffects {
        let deadline = ContinuousClock.now.advanced(by: .seconds(30))
        while ContinuousClock.now < deadline {
            if let effects = try? await getEffects(digest) {
                return effects
            }
            try? await Task.sleep(for: .milliseconds(200))
        }
        throw SuiLaunchError(description: "no effects for \(digest) within 30s")
    }

    private func getEffects(_ digest: String) async throws -> Sui_Rpc_V2_TransactionEffects {
        try await withLedgerServiceClient { ledger in
            var request = Sui_Rpc_V2_GetTransactionRequest()
            request.digest = digest
            request.readMask.paths = ["effects"]
            let response = try await ledger.getTransaction(request: ClientRequest(message: request))
            return response.transaction.effects
        }
    }

    /// Polls ``SuiGRPCClient/nativeBalance(of:)`` for `address` until it
    /// differs from `previous` — the balance index updates on checkpoint
    /// commit, slightly after `waitForEffects(_:)` sees the transaction's
    /// own effects.
    func waitForBalanceChange(of address: SuiAddress, from previous: UInt64) async throws -> UInt64 {
        let deadline = ContinuousClock.now.advanced(by: .seconds(30))
        while ContinuousClock.now < deadline {
            if let balance = try? await client().nativeBalance(of: address), balance != previous {
                return balance
            }
            try? await Task.sleep(for: .milliseconds(200))
        }
        throw SuiLaunchError(description: "\(address.string)'s balance didn't change from \(previous) within 30s")
    }

    private func hexDecoded(_ string: String) throws -> Data {
        let hex = string.hasPrefix("0x") ? String(string.dropFirst(2)) : string
        guard hex.count.isMultiple(of: 2) else {
            throw SuiLaunchError(description: "'\(string)' has an odd number of hex digits")
        }
        var data = Data(capacity: hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else {
                throw SuiLaunchError(description: "'\(string)' is not valid hex")
            }
            data.append(byte)
            index = next
        }
        return data
    }

    private func transport() throws -> HTTP2ClientTransport.Posix {
        do {
            return try HTTP2ClientTransport.Posix(
                target: .dns(host: "127.0.0.1", port: Int(rpcPort)),
                transportSecurity: .plaintext
            )
        } catch {
            throw SuiLaunchError(description: "failed to build transport to 127.0.0.1:\(rpcPort): \(error.localizedDescription)")
        }
    }

    private func withLedgerServiceClient<Result: Sendable>(
        _ body: @escaping (Sui_Rpc_V2_LedgerService.Client<HTTP2ClientTransport.Posix>) async throws -> Result
    ) async throws -> Result {
        try await withGRPCClient(transport: try transport()) { grpcClient in
            try await body(Sui_Rpc_V2_LedgerService.Client(wrapping: grpcClient))
        }
    }

    private func withStateServiceClient<Result: Sendable>(
        _ body: @escaping (Sui_Rpc_V2_StateService.Client<HTTP2ClientTransport.Posix>) async throws -> Result
    ) async throws -> Result {
        try await withGRPCClient(transport: try transport()) { grpcClient in
            try await body(Sui_Rpc_V2_StateService.Client(wrapping: grpcClient))
        }
    }
}
