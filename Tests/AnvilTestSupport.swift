// Shared local-Anvil test infrastructure: node lifecycle, an in-memory
// DatabaseService factory, and a funded deployer for a throwaway mock
// ERC-20 — mirrors the "real infrastructure, not a mock" approach already
// used by WalletKit's own EthereumAnvilTests.swift. Used by both
// DatabaseServiceDeleteAllTests.swift and TransactionServiceTests.swift so
// neither duplicates this setup.

import BigInt
import Foundation
import SwiftData
import WalletKitTesting
@testable import ReefrWallet

// MARK: - Node & database

func startAnvilNode() async throws -> AnvilNode {
    let repositoryURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    return try await AnvilNode.start(workingDirectory: repositoryURL)
}

func makeDatabaseService() throws -> DatabaseService {
    let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
    let container = try ModelContainer(
        for: AccountModel.self,
            BalanceModel.self,
            BlockchainModel.self,
            KeyStoreModel.self,
            TokenModel.self,
            SavedAddressModel.self,
            WalletTransactionModel.self,
            WalletTransactionEffectModel.self,
            WalletTransactionSyncStateModel.self,
            configurations: configuration
    )

    return DatabaseService(modelContainer: container)
}

func makeWatchOnlyKeyStore(
    databaseService: DatabaseService,
    name: String = "Anvil Watch-Only Test Key Store"
) async throws -> KeyStore {
    let keyStoreId = try await databaseService.insertKeyStore(KeyStore(
        deviceId: nil,
        kind: .watchOnly,
        name: name,
        rawKey: nil,
        transport: nil,
        vendor: nil
    ))

    return KeyStore(
        deviceId: nil,
        id: keyStoreId,
        kind: .watchOnly,
        name: name,
        rawKey: nil,
        transport: nil,
        vendor: nil
    )
}

/// A `.local` keystore backed by a freshly-generated mnemonic — able to
/// actually sign, unlike the watch-only keystores elsewhere in this file.
func makeLocalKeyStore(
    databaseService: DatabaseService,
    name: String = "Anvil Local Test Key Store"
) async throws -> KeyStore {
    let rawKey = Mnemonic.generate(wordCount: .words12).toSeed().exportRaw()
    let keyStoreId = try await databaseService.insertKeyStore(KeyStore(
        deviceId: nil,
        kind: .local,
        name: name,
        rawKey: rawKey,
        transport: nil,
        vendor: nil
    ))

    return KeyStore(
        deviceId: nil,
        id: keyStoreId,
        kind: .local,
        name: name,
        rawKey: rawKey,
        transport: nil,
        vendor: nil
    )
}

// MARK: - Deployer & mock ERC-20

/// Signs and broadcasts transactions on behalf of a funded account — used to
/// deploy and mint the mock ERC-20.
struct Deployer {
    let node: AnvilNode
    let address: EthereumAddress
    let client: EthereumRPCClient
    let gasPrice: BigUInt
    let signer: EthereumPKeySigner

    func sendAndConfirm(to: EthereumAddress?, data: Data, gasLimit: BigUInt) async throws -> TransactionReceipt {
        let nonce = try await node.transactionCount(of: address)
        let transaction = UnsignedLegacyTransaction(
            nonce: nonce,
            gasPrice: gasPrice,
            gasLimit: gasLimit,
            to: to,
            value: 0,
            data: data,
            chainId: node.chainId
        )
        let signed = try await signer.sign(transaction: transaction.signingData)
        let hash = try await client.broadcast(signed)
        let receipt = try await node.waitForReceipt(hash)
        guard receipt.status == "0x1" else {
            throw AnvilLaunchError(description: "transaction from deployer reverted")
        }
        return receipt
    }
}

func makeFundedDeployer(node: AnvilNode, blockchain: WKBlockchain) async throws -> Deployer {
    let privateKey = try randomEthereumPrivateKey()
    let derivationPath = try DerivationPath(blockchain, accountIndex: 0, curve: .secp256k1)
    let signer = try EthereumPKeySigner(chainId: node.chainId, privateKey: privateKey, derivationPath: derivationPath)
    let address = try signer.address()
    try await node.setBalance(address, wei: BigUInt(10_000_000_000_000_000_000))

    return Deployer(
        node: node,
        address: address,
        client: EthereumRPCClient(endpoint: node.endpoint, chainId: node.chainId),
        gasPrice: try await node.gasPrice(),
        signer: signer
    )
}

func deployMockUSDC(deployer: Deployer) async throws -> EthereumAddress {
    let receipt = try await deployer.sendAndConfirm(to: nil, data: mockUSDCCreationBytecode, gasLimit: 1_000_000)
    guard let contractAddressHex = receipt.contractAddress else {
        throw AnvilLaunchError(description: "mock USDC deployment produced no contract address")
    }

    return try EthereumAddress(string: contractAddressHex)
}

func mintMockUSDC(
    deployer: Deployer,
    mockUSDCAddress: EthereumAddress,
    wallet: EthereumAddress,
    amount: BigUInt
) async throws {
    _ = try await deployer.sendAndConfirm(
        to: mockUSDCAddress,
        data: EthereumABI.encodeCall(
            selector: EthereumABI.selector("mint(address,uint256)"),
            parameters: [.address(wallet), .uint256(amount)]
        ),
        gasLimit: 100_000
    )
}

func fundWallet(
    deployer: Deployer,
    wallet: EthereumAddress,
    mockUSDCAddress: EthereumAddress,
    native: BigUInt,
    usdc: BigUInt
) async throws {
    try await deployer.node.setBalance(wallet, wei: native)
    try await mintMockUSDC(deployer: deployer, mockUSDCAddress: mockUSDCAddress, wallet: wallet, amount: usdc)
}

/// Registers the mock ERC-20 in the database so `BalancesService`'s sync
/// discovers it — mirrors how a real token gets onto a blockchain's token list.
func registerMockUSDCToken(
    databaseService: DatabaseService,
    blockchain: WKBlockchain,
    mockUSDCAddress: EthereumAddress
) async throws {
    try await databaseService.insertToken(
        Token(
            address: mockUSDCAddress.checksummed,
            blockchain: blockchain,
            decimalsCount: 6,
            imageURL: nil,
            isHidden: false,
            isIncludedInBalance: true,
            isNativeToken: false,
            name: "Mock USDC",
            symbol: "USDC",
            usdPrice: nil
        ),
        blockchain: blockchain
    )
}

// MARK: - Misc helpers

/// Generates a fresh secp256k1 key for wallets that only need an address
/// (deployer, watch-only recipients) — no need for a shared/well-known key.
func randomEthereumPrivateKey() throws -> PrivateKey {
    let rawBytes = Data((0 ..< 32).map { _ in UInt8.random(in: 0 ... 255) })
    return try PrivateKey(curve: .secp256k1, rawBytes: rawBytes)
}

/// Parses a JSON-RPC "Quantity" hex string, e.g. a receipt's `gasUsed` or
/// `effectiveGasPrice`.
func hexQuantity(_ hex: String) -> BigUInt {
    let body = hex.hasPrefix("0x") ? String(hex.dropFirst(2)) : hex
    return BigUInt(body, radix: 16) ?? 0
}

/// Decodes a `0x`-prefixed hex string into `Data`. WalletKit's own
/// `Data(hexString:)` is internal, so this test target needs its own copy —
/// mirrors the private `String.hexDecoded` helper in
/// `WalletKit/Tests/Blockchains/Ethereum/EthereumAnvilTests.swift`.
func decodeHex(_ hexString: String) -> Data {
    let hex = hexString.hasPrefix("0x") ? String(hexString.dropFirst(2)) : hexString
    var data = Data(capacity: hex.count / 2)
    var index = hex.startIndex
    while index < hex.endIndex {
        let next = hex.index(index, offsetBy: 2)
        data.append(UInt8(hex[index ..< next], radix: 16)!) // swiftlint:disable:this force_unwrapping
        index = next
    }
    return data
}

/// The compiled creation bytecode for a minimal test-only ERC-20 (hardcoded
/// name/symbol, unrestricted mint) — the same contract WalletKit's
/// `MockUSDCBytecode.swift` deploys for `EthereumAnvilTests.swift`, copied
/// here since that file lives in WalletKit's own test target. See that
/// file's header comment for the Solidity source and how this was compiled.
let mockUSDCCreationBytecode = decodeHex(
    // swiftlint:disable:next line_length
    "0x6080604052348015600e575f5ffd5b506103ae8061001c5f395ff3fe608060405234801561000f575f5ffd5b5060043610610060575f3560e01c806306fdde0314610064578063313ce567146100a257806340c10f19146100bc57806370a08231146100d157806395d89b41146100fe578063a9059cbb14610121575b5f5ffd5b61008c604051806040016040528060098152602001684d6f636b205553444360b81b81525081565b60405161009991906102a6565b60405180910390f35b6100aa600681565b60405160ff9091168152602001610099565b6100cf6100ca3660046102f6565b610144565b005b6100f06100df36600461031e565b5f6020819052908152604090205481565b604051908152602001610099565b61008c604051806040016040528060048152602001635553444360e01b81525081565b61013461012f3660046102f6565b6101b4565b6040519015158152602001610099565b6001600160a01b0382165f908152602081905260408120805483929061016b908490610352565b90915550506040518181526001600160a01b038316905f907fddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef9060200160405180910390a35050565b335f9081526020819052604081205482111561020d5760405162461bcd60e51b8152602060048201526014602482015273696e73756666696369656e742062616c616e636560601b604482015260640160405180910390fd5b335f908152602081905260408120805484929061022b908490610365565b90915550506001600160a01b0383165f9081526020819052604081208054849290610257908490610352565b90915550506040518281526001600160a01b0384169033907fddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef9060200160405180910390a35060015b92915050565b602081525f82518060208401528060208501604085015e5f604082850101526040601f19601f83011684010191505092915050565b80356001600160a01b03811681146102f1575f5ffd5b919050565b5f5f60408385031215610307575f5ffd5b610310836102db565b946020939093013593505050565b5f6020828403121561032e575f5ffd5b610337826102db565b9392505050565b634e487b7160e01b5f52601160045260245ffd5b808201808211156102a0576102a061033e565b818103818111156102a0576102a061033e56fea26469706673582212200b59cd1cd101f07cbeba3ebf884340311a05cb5e06312b51ea59aabc144d458064736f6c63430008230033"
)
