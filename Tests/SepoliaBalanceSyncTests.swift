// Public-testnet version of `RelaunchBalanceSyncTests` for the reported case:
// a USDC transfer received while the app is closed must show up — balance and
// transaction — on relaunch, and the sidebar "Update" refresh must catch up on
// its own.
//
// Unlike the local-node suite, accounts use the chain's default endpoints (no
// RPC override), so this also covers indexer-backed forward sync (Blockscout).
//
// Opt-in: it spends Sepolia gas and needs two pre-funded accounts. Runs when
// `REEFR_TESTNET_MNEMONIC` is set — `Project.swift` forwards it into the test
// schemes from `TUIST_REEFR_TESTNET_MNEMONIC` at generation. The accounts are
// m/44'/60'/0'/0/0 (sender) and /1 (recipient). Both need Sepolia ETH for gas;
// the sender needs some USDC: each run sends a random amount up to its whole
// balance (in base units), and every USDC sent to the
// recipient is sent back, so the token balances never deplete.

import BigInt
import Foundation
import Testing
import WalletKit
@testable import ReefrWallet

@Suite(
    .serialized,
    .timeLimit(.minutes(5)),
    .enabled(if: ProcessInfo.processInfo.environment["REEFR_TESTNET_MNEMONIC"] != nil)
)

struct SepoliaBalanceSyncTests {
    /// Circle's USDC on Sepolia.
    static let usdc = "0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238"
    /// Enough for a couple of ERC-20 transfers at Sepolia gas prices.
    static let minimumGas: BigUInt = 200_000_000_000_000

    static var mnemonic: String {
        ProcessInfo.processInfo.environment["REEFR_TESTNET_MNEMONIC"] ?? localNodeMnemonic
    }

    @Test // swiftlint:disable:next function_body_length
    func usdcTransferCatchesUpAfterRelaunchAndUpdate() async throws {
        let blockchain = Blockchain.evm(.ethereum(.sepolia))
        let chainId: UInt64 = 11_155_111

        let signers = try (0 ..< 2).map { index in
            let path = "m/44'/60'/0'/0/\(index)"
            return try EthereumPKeySigner(
                chainId: chainId,
                privateKey: derivedPrivateKey(mnemonic: Self.mnemonic, path: path, curve: .secp256k1),
                derivationPath: DerivationPath(string: path)
            )
        }

        let addresses = try signers.map { try $0.address() }
        let databaseService = try makeDatabaseService()
        let accounts = try await insertScenarioAccounts(
            addresses: addresses.map(\.string),
            blockchain: blockchain,
            rpcURL: nil,
            databaseService: databaseService
        )

        let client = try BlockchainClientProvider().ethereumClient(for: accounts[0])
        let token = try EthereumAddress(string: Self.usdc)

        try await requireFunding(client: client, addresses: addresses, token: token)

        // A random amount up to the sender's whole balance; the same amount is sent back.
        let amount = try randomTransferAmount(
            available: try await client.erc20Balance(token: token, owner: addresses[0])
        )

        let send: (Int, Int) async throws -> String = { from, to in
            try await Self.sendUSDC(
                client: client,
                signer: signers[from],
                recipient: addresses[to],
                amount: amount
            )
        }

        var scenario = RelaunchScenario(
            assets: [nil, token.string],
            databaseService: databaseService,
            recipient: accounts[1],
            sender: accounts[0]
        ) { _, _ in try await send(0, 1) }

        // Public endpoints and the indexer lag behind the chain: allow one minute
        // for a transfer to be mined and indexed (local nodes get 30 seconds).
        scenario.timeout = .seconds(60)

        // 1. Launch: initial balances are saved.
        let firstLaunch = AppSession(databaseService: databaseService)
        await firstLaunch.launch()
        try await scenario.waitUntilBalancesMatchChain(stage: "Sepolia initial sync")
        await firstLaunch.close(scenario.accounts)

        var owesTransferBack = false

        do {
            // 2. Closed: the recipient receives USDC.
            let incoming = try await send(0, 1)
            owesTransferBack = true

            // 3. Relaunch: balance and transaction catch up with no user action.
            let relaunch = AppSession(databaseService: databaseService)
            await relaunch.launch()

            try await scenario.waitUntilBalancesMatchChain(
                stage: "Sepolia relaunch",
                expectedTransactions: [incoming]
            )

            await relaunch.close(scenario.accounts)

            // 4. Closed: send the same amount back, then only the "Update"
            //    button's refresh runs.
            _ = try await send(1, 0)
            owesTransferBack = false

            let manualUpdate = BalancesService(databaseService: databaseService)

            // Public RPC nodes are load-balanced and can answer from a block behind the
            // receipt just seen, so an Update right after a transfer may read the old
            // balance. The button can be pressed again: allow it a few more tries.
            let deadline = ContinuousClock.now.advanced(by: .seconds(30))
            var mismatches: [String]

            repeat {
                for account in scenario.accounts {
                    try await manualUpdate.updateBalances(account)
                }

                mismatches = try await scenario.currentMismatches(expectedTransactions: [])

                if !mismatches.isEmpty {
                    try await Task.sleep(for: .seconds(3))
                }
            } while !mismatches.isEmpty && ContinuousClock.now < deadline

            #expect(mismatches.isEmpty, "Sepolia Update: \(mismatches.joined(separator: "; "))")
        } catch {
            if owesTransferBack {
                _ = try? await send(1, 0)
            }

            throw error
        }
    }
}

private extension SepoliaBalanceSyncTests {
    func requireFunding(
        client: EthereumRPCClient,
        addresses: [EthereumAddress],
        token: EthereumAddress
    ) async throws {
        for address in addresses {
            let gas = try await client.nativeBalance(of: address)
            try #require(
                gas >= Self.minimumGas,
                "\(address.string) has \(gas) wei on Sepolia; fund it with at least \(Self.minimumGas) wei for gas."
            )
        }

        let usdc = try await client.erc20Balance(token: token, owner: addresses[0])
        try #require(
            usdc >= 1,
            "\(addresses[0].string) has no USDC on Sepolia."
        )
    }

    static func sendUSDC(
        client: EthereumRPCClient,
        signer: EthereumPKeySigner,
        recipient: EthereumAddress,
        amount: BigUInt
    ) async throws -> String {
        let unsigned = try await EthereumTransactionBuilder(client: client).buildTransfer(
            sender: try signer.address(),
            recipient: recipient,
            amount: amount,
            token: usdc,
            options: []
        )

        let hash = try await client.broadcast(try await signer.sign(transaction: unsigned))
        try await waitForSuccess(hash, client: client)
        return hash
    }

    /// Polls for a mined receipt for up to a minute (Sepolia blocks are 12 seconds apart).
    static func waitForSuccess(_ hash: String, client: EthereumRPCClient) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(60))
        let params = try JSONSerialization.data(withJSONObject: [hash])

        while ContinuousClock.now < deadline {
            let raw = try await client.request(method: "eth_getTransactionReceipt", params: params)

            if let receipt = try JSONSerialization.jsonObject(with: raw, options: .fragmentsAllowed) as? [String: Any] {
                try #require(receipt["status"] as? String == "0x1", "Sepolia transaction \(hash) reverted.")
                return
            }

            try await Task.sleep(for: .seconds(3))
        }

        throw SepoliaTestError(description: "Sepolia transaction \(hash) wasn't mined within 60 seconds.")
    }
}

private struct SepoliaTestError: Swift.Error, CustomStringConvertible {
    let description: String
}
