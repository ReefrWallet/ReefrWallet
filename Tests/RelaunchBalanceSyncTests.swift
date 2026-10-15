// Regression coverage for "balances don't update after the initial save":
// on every chain with a local node (Bitcoin excluded), a transfer received
// while the app is closed must show up — balance and transaction — on the
// next launch, and the manual "Update" refresh must catch up on its own.
// See `RelaunchScenario` for the shared lifecycle.

import BigInt
import Foundation
import Testing
import WalletKit
import WalletKitTesting
@testable import ReefrWallet

@Suite(.timeLimit(.minutes(3)), .serialized, .localNode)
struct RelaunchBalanceSyncTests {
    @Test // swiftlint:disable:next function_body_length
    func evmBalancesAndTransactionsCatchUpAfterRelaunch() async throws {
        let node = try await startAnvilNode()
        defer { node.stop() }

        let signers = try (0 ..< 2).map { index in
            let path = "m/44'/60'/0'/0/\(index)"
            return try EthereumPKeySigner(
                chainId: node.chainId,
                privateKey: derivedPrivateKey(mnemonic: localNodeMnemonic, path: path, curve: .secp256k1),
                derivationPath: DerivationPath(string: path)
            )
        }

        let addresses = try signers.map { try $0.address() }
        let deployer = try await makeFundedDeployer(node: node, blockchain: .evm(.ethereum(.sepolia)))
        let usdc = try await deployMockUSDC(deployer: deployer)

        // The recipient starts with 3.06 USDC, like the report.
        try await fundWallet(
            deployer: deployer,
            wallet: addresses[0],
            mockUSDCAddress: usdc,
            native: 10_000_000_000_000_000_000,
            usdc: 1_000_000_000
        )

        try await fundWallet(
            deployer: deployer,
            wallet: addresses[1],
            mockUSDCAddress: usdc,
            native: 1_000_000_000_000_000_000,
            usdc: 3_060_000
        )

        let databaseService = try makeDatabaseService()
        let accounts = try await insertScenarioAccounts(
            addresses: addresses.map(\.string),
            blockchain: .evm(.ethereum(.sepolia)),
            rpcURL: node.endpoint,
            databaseService: databaseService
        )

        var scenario = RelaunchScenario(
            assets: [nil, usdc.string],
            databaseService: databaseService,
            recipient: accounts[1],
            sender: accounts[0]
        ) { asset, amount in
            guard let asset else {
                return try await node.send(signer: signers[0], to: addresses[1], value: amount, gasLimit: 21_000)
            }

            return try await node.send(
                signer: signers[0],
                to: try EthereumAddress(string: asset),
                data: EthereumABI.encodeCall(
                    selector: EthereumABI.selector("transfer(address,uint256)"),
                    parameters: [.address(addresses[1]), .uint256(amount)]
                ),
                gasLimit: 100_000
            )
        }

        // Anvil only mines on demand: open a gap wider than one 10-block
        // forward-scan page between the stored head and the tip.
        scenario.afterTransfers = { try await node.mine(blocks: 25) }

        try await scenario.run(nativeAmount: 250_000_000_000_000_000)
    }

    @Test
    func solanaBalancesAndTransactionsCatchUpAfterRelaunch() async throws {
        let node = try await SolanaNode.start()
        defer { node.stop() }

        let signers = try (0 ..< 2).map { index in
            let path = "m/44'/501'/\(index)'/0'"
            return try SolanaPKeySigner(
                network: .devnet,
                privateKey: derivedPrivateKey(mnemonic: localNodeMnemonic, path: path, curve: .ed25519),
                derivationPath: DerivationPath(string: path)
            )
        }

        let addresses = try signers.map { try $0.address() }

        for address in addresses {
            _ = try await node.airdrop(to: address, lamports: 2_000_000_000)
        }

        let client = SolanaRPCClient(endpoint: node.rpcURL)
        let builder = SolanaTransactionBuilder(client: client)
        let mint = try await node.mintSPLToken(decimals: 6, to: addresses[0], amount: 1_000_000_000)

        let transfer: (String?, BigUInt) async throws -> String = { asset, amount in
            let unsigned = try await builder.buildTransfer(
                sender: addresses[0],
                recipient: addresses[1],
                amount: amount,
                token: asset,
                options: []
            )

            let signature = try await client.broadcast(
                transaction: unsigned,
                signature: try await signers[0].sign(transaction: unsigned)
            )

            try await node.waitForConfirmation(signature: signature)
            return signature
        }

        // The recipient starts with a small token balance, like the report.
        _ = try await transfer(mint.string, 3_060_000)

        let databaseService = try makeDatabaseService()
        let accounts = try await insertScenarioAccounts(
            addresses: addresses.map(\.string),
            blockchain: .solana(.devnet),
            rpcURL: node.rpcURL,
            databaseService: databaseService
        )

        let scenario = RelaunchScenario(
            assets: [nil, mint.string],
            databaseService: databaseService,
            recipient: accounts[1],
            sender: accounts[0],
            transfer: transfer
        )

        try await scenario.run(nativeAmount: 250_000_000)
    }

    @Test
    func suiBalancesAndTransactionsCatchUpAfterRelaunch() async throws {
        let node = try await SuiNode.start()
        defer { node.stop() }

        let signers = try (0 ..< 2).map { index in
            let path = "m/44'/784'/0'/0'/\(index)'"
            return try SuiPKeySigner(
                curve: .ed25519,
                privateKey: derivedPrivateKey(mnemonic: localNodeMnemonic, path: path, curve: .ed25519),
                derivationPath: DerivationPath(string: path)
            )
        }

        let addresses = try signers.map { try $0.address() }

        for address in addresses {
            try await node.faucet(address)
            try await node.waitForSuiCoinCount(of: address, atLeast: 1)
        }

        let rpcURL = try #require(URL(string: "http://127.0.0.1:\(node.rpcPort)"))
        let client = SuiGRPCClient(host: "127.0.0.1", port: Int(node.rpcPort), useTLS: false)
        let builder = SuiTransactionBuilder(client: client)
        let databaseService = try makeDatabaseService()
        let accounts = try await insertScenarioAccounts(
            addresses: addresses.map(\.string),
            blockchain: .sui(.testnet),
            rpcURL: rpcURL,
            databaseService: databaseService
        )

        // Sui custom coins need a published Move package, so only native SUI
        // is exercised here.
        let scenario = RelaunchScenario(
            assets: [nil],
            databaseService: databaseService,
            recipient: accounts[1],
            sender: accounts[0]
        ) { _, amount in
            let unsigned = try await builder.buildTransfer(
                sender: addresses[0],
                recipient: addresses[1],
                amount: amount,
                token: nil
            )

            let digest = try await client.broadcast(
                transactionData: unsigned,
                signature: try await signers[0].sign(transaction: unsigned)
            )

            _ = try await node.waitForEffects(digest)
            return digest
        }

        try await scenario.run(nativeAmount: 250_000_000)
    }
}
