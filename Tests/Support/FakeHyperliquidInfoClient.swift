import Foundation
import Synchronization
import Testing
@testable import ReefrWallet

/// Recorded `/info` responses from `TestVectors/Hyperliquid` (see its README).
struct HyperliquidFixture {
    /// Hyperliquid's own account value when the fixture was recorded.
    let referenceAccountValue: Decimal?
    let responses: [HyperliquidRequest: Data]
    let user: String

    /// - Parameters:
    ///   - name: The account file, e.g. `hyperliquid-unified-lending`.
    ///   - metadata: The network's metadata file.
    init(_ name: String, metadata: String = "hyperliquid-mainnet-metadata") throws {
        let account = try Self.object(name)
        let meta = try Self.object(metadata)
        let user = try #require(account["address"] as? String)
        let clearinghouses = try #require(account["clearinghouseState"] as? [String: Any])

        var responses: [HyperliquidRequest: Data] = try [
            .allPerpMetas: Self.data(meta["allPerpMetas"]),
            .borrowLendUserState(user: user): Self.data(account["borrowLendUserState"]),
            .delegatorSummary(user: user): Self.data(account["delegatorSummary"]),
            .perpDexs: Self.data(meta["perpDexs"]),
            .spotClearinghouseState(user: user): Self.data(account["spotClearinghouseState"]),
            .spotMetaAndAssetCtxs: Self.data(meta["spotMetaAndAssetCtxs"]),
            .userAbstraction(user: user): Self.data(account["userAbstraction"]),
            .userVaultEquities(user: user): Self.data(account["userVaultEquities"])
        ]

        for (dex, state) in clearinghouses {
            responses[.clearinghouseState(user: user, dex: dex)] = try Self.data(state)
        }

        self.responses = responses
        referenceAccountValue = (account["referenceAccountValue"] as? String).flatMap { Decimal(string: $0) }
        self.user = user
    }

    func input(network: HyperliquidNetwork = .mainnet) async throws -> HyperliquidValuation.Input {
        let client = FakeHyperliquidInfoClient(responses)
        let metadata = try await HyperliquidMetadataCache().metadata(network, client: client)
        var clearinghouses: [String: Hyperliquid.ClearinghouseState] = [:]

        for dex in metadata.dexes {
            clearinghouses[dex] = try await client.decoded(.clearinghouseState(user: user, dex: dex), network: network)
        }

        return try await HyperliquidValuation.Input(
            borrowLend: client.decoded(.borrowLendUserState(user: user), network: network),
            clearinghouses: clearinghouses,
            mode: client.decoded(.userAbstraction(user: user), network: network),
            network: network,
            perpMetas: metadata.perpMetas,
            spot: client.decoded(.spotClearinghouseState(user: user), network: network),
            spotMeta: metadata.spot,
            stake: client.decoded(.delegatorSummary(user: user), network: network),
            unqueriedDexCount: 0,
            vaults: client.decoded(.userVaultEquities(user: user), network: network)
        )
    }

    private static func data(_ object: Any?) throws -> Data {
        let object = try #require(object)
        return try JSONSerialization.data(withJSONObject: object, options: [.fragmentsAllowed])
    }

    private static func object(_ name: String) throws -> [String: Any] {
        let url = try #require(
            Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Hyperliquid")
                ?? Bundle.module.url(forResource: name, withExtension: "json")
        )

        return try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }
}

/// Serves canned responses and counts requests; unknown requests fail.
final class FakeHyperliquidInfoClient: HyperliquidInfoClient {
    struct Missing: Error {
        let request: HyperliquidRequest
    }

    private let state: Mutex<(responses: [HyperliquidRequest: Data], counts: [String: Int])>

    init(_ responses: [HyperliquidRequest: Data]) {
        state = Mutex((responses, [:]))
    }

    func count(_ type: String) -> Int {
        state.withLock { $0.counts[type, default: 0] }
    }

    func data(_ request: HyperliquidRequest, network: HyperliquidNetwork) async throws -> Data {
        try state.withLock { state in
            state.counts[request.type, default: 0] += 1

            guard let data = state.responses[request] else {
                throw Missing(request: request)
            }

            return data
        }
    }

    func set(_ request: HyperliquidRequest, json: String) {
        state.withLock { $0.responses[request] = Data(json.utf8) }
    }
}
