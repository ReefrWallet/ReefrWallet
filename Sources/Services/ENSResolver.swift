import WalletKit

/// Resolves ENS names to addresses on Ethereum mainnet via the registry and the name's resolver.
///
/// Names are only lowercased before hashing, not UTS-46 normalized, so names with
/// non-ASCII labels are not supported. Wildcard (ENSIP-10) and CCIP-Read names are not either.
struct ENSResolver: Sendable {
    // swiftlint:disable force_try
    private static let registry = try! EthereumAddress(string: "0x00000000000C2E074eC69A0dFb2997BA6C7d2e1e")
    // swiftlint:enable force_try

    let clientProvider: BlockchainClientProvider

    /// Whether `input` looks like an ENS name: dotted, no whitespace and not a hex address.
    static func isName(_ input: String) -> Bool {
        let name = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard
            name.contains("."),
            !name.hasPrefix("0x"),
            name.rangeOfCharacter(from: .whitespacesAndNewlines) == nil
        else {
            return false
        }

        return name.split(separator: ".", omittingEmptySubsequences: false).allSatisfy { !$0.isEmpty }
    }

    /// Resolves `name` through Ethereum mainnet.
    ///
    /// - Throws: ``ReefrError/notFound`` if the name has no resolver or no address set.
    func resolve(_ name: String) async throws -> EthereumAddress {
        try await resolve(name, client: clientProvider.ethereumClient(blockchain: .evm(.ethereum(.mainnet))))
    }

    /// Resolves `name` with `client`, which must be connected to Ethereum mainnet.
    func resolve(_ name: String, client: EthereumRPCClient) async throws -> EthereumAddress {
        let node = Self.namehash(name)
        let resolverData = EthereumABI.encodeCall(
            selector: EthereumABI.selector("resolver(bytes32)"),
            parameters: [.bytes32(node)]
        )

        guard let resolverWord = EthereumABI.words(try await client.call(to: Self.registry, data: resolverData)).first
        else {
            throw BlockchainClientError.decodingFailed(reason: "empty resolver(bytes32) response")
        }

        let resolver = try EthereumABI.decodeAddress(resolverWord)
        guard resolver != EthereumAddress.zero else {
            throw ReefrError.notFound
        }

        let addressData = EthereumABI.encodeCall(
            selector: EthereumABI.selector("addr(bytes32)"),
            parameters: [.bytes32(node)]
        )

        guard let addressWord = EthereumABI.words(try await client.call(to: resolver, data: addressData)).first else {
            throw BlockchainClientError.decodingFailed(reason: "empty addr(bytes32) response")
        }

        let address = try EthereumABI.decodeAddress(addressWord)
        guard address != EthereumAddress.zero else {
            throw ReefrError.notFound
        }

        return address
    }

    static func namehash(_ name: String) -> Data {
        name.lowercased().split(separator: ".").reversed().reduce(Data(repeating: 0, count: 32)) { node, label in
            EthereumABI.keccak256(node + EthereumABI.keccak256(Data(label.utf8)))
        }
    }
}
