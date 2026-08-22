// Tests for Sources/Static/Blockchains/Ethereum/EthereumRPCClient.swift —
// the JSON-RPC method names/params each API sends, and the response
// decoding (including its `BlockchainClientError` failure modes). Uses
// StubURLProtocol so these exercise the real `URLSession`/`JSONRPCClient`
// pipeline without a real network call.
//
// `erc20TokenInfoFetchesUSDCsMetadataFromTheLiveMainnet` and
// `chainlinkFeedPriceForAStablecoinIsWithinOnePercentOfOneDollar` are the
// exceptions: they hit a real public mainnet RPC endpoint. Unlike every
// other method here, `erc20TokenInfo(token:)` fires three concurrent
// `eth_call`s (name/symbol/decimals) over one `StubURLProtocol.Session`,
// which only holds a single canned response and captures a single
// last-request/body — not enough to give each of the three calls its own
// distinct response; real USDC — a stable, well-known contract whose
// metadata isn't going to change — sidesteps that rather than extending the
// stub for one test. The Chainlink feed price test is a genuine end-to-end
// check (ENS resolution -> feed address -> live oracle price) that a canned
// response can't stand in for. `withKnownIssue(isIntermittent: true)` keeps
// a lack of network access (sandboxed CI, offline dev) from failing these,
// per the same reasoning as SuiGRPCClientTests.

import BigInt
import Foundation
import Testing
@testable import WalletKit

// swiftlint:disable force_try
private let someAddress = try! EthereumAddress(rawBytes: Data(repeating: 0xAB, count: 20))
private let someOtherAddress = try! EthereumAddress(rawBytes: Data(repeating: 0xCD, count: 20))
// swiftlint:enable force_try

/// Left-pads `data` to one 32-byte ABI word.
private func word(_ data: Data) -> Data {
    Data(repeating: 0, count: 32 - data.count) + data
}

/// A 32-byte ABI word encoding `value` as an unsigned big-endian integer.
private func word(_ value: BigUInt) -> Data {
    word(value.serialize())
}

/// A 32-byte ABI word encoding `value` as a two's-complement signed integer
/// — computed independently of `EthereumABI.decodeInt256`, the same
/// "verify against an independent computation" principle the Sui address
/// tests use.
private func word(_ value: BigInt) -> Data {
    guard value.sign == .minus else { return word(value.magnitude) }
    return word((BigUInt(1) << 256) - value.magnitude)
}

/// A stub session that returns `result` as a successful JSON-RPC response.
private func stubbedResult(_ result: String) -> StubURLProtocol.Session {
    StubURLProtocol.makeSession(response: .success(body: Data(#"{"jsonrpc":"2.0","id":1,"result":"\#(result)"}"#.utf8)))
}

struct EthereumRPCClientTests {
    private func makeClient(_ stub: StubURLProtocol.Session, chainId: UInt64 = 1) -> EthereumRPCClient {
        EthereumRPCClient(endpoint: URL(string: "https://example.com/rpc")!, chainId: chainId, session: stub.urlSession)
    }

    private func capturedEnvelope(_ stub: StubURLProtocol.Session) throws -> [String: Any] {
        let body = try #require(stub.capturedBody)
        return try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
    }

    @Test func initStoresTheGivenChainIdDefaultingToMainnet() {
        let stub = StubURLProtocol.makeSession(response: .success(body: Data()))
        #expect(makeClient(stub).chainId == 1)
        #expect(makeClient(stub, chainId: 11155111).chainId == 11155111)
    }

    // MARK: - nativeBalance

    @Test func nativeBalanceParsesTheQuantityHexResponse() async throws {
        let stub = stubbedResult("0x1a")
        #expect(try await makeClient(stub).nativeBalance(of: someAddress) == 26)
    }

    @Test func nativeBalanceAcceptsAnOddDigitCountQuantity() async throws {
        // "Quantity" hex (unlike "Data" hex) is minimal-digit, so an odd
        // count is valid, e.g. "0x1" for 1 wei.
        let stub = stubbedResult("0x1")
        #expect(try await makeClient(stub).nativeBalance(of: someAddress) == 1)
    }

    @Test func nativeBalanceOfZeroIsZero() async throws {
        let stub = stubbedResult("0x0")
        #expect(try await makeClient(stub).nativeBalance(of: someAddress) == 0)
    }

    @Test func nativeBalanceThrowsDecodingFailedForInvalidQuantityHex() async throws {
        let client = makeClient(stubbedResult("0xzz"))
        await #expect(throws: BlockchainClientError.self) {
            _ = try await client.nativeBalance(of: someAddress)
        }
    }

    @Test func nativeBalanceSendsEthGetBalanceWithTheAddressAndLatestTag() async throws {
        let stub = stubbedResult("0x0")
        _ = try await makeClient(stub).nativeBalance(of: someAddress)

        let envelope = try capturedEnvelope(stub)
        #expect(envelope["method"] as? String == "eth_getBalance")
        #expect(envelope["params"] as? [String] == [someAddress.string, "latest"])
    }

    // MARK: - call

    @Test func callSendsEthCallWithTheToAndDataObjectAndTheLatestTag() async throws {
        let stub = stubbedResult("0x")
        _ = try await makeClient(stub).call(to: someAddress, data: Data([0xDE, 0xAD]))

        let envelope = try capturedEnvelope(stub)
        #expect(envelope["method"] as? String == "eth_call")

        let params = try #require(envelope["params"] as? [Any])
        #expect(params.count == 2)
        #expect(params[1] as? String == "latest")

        let callObject = try #require(params[0] as? [String: Any])
        #expect(callObject["to"] as? String == someAddress.string)
        #expect(callObject["data"] as? String == "0xdead")
    }

    @Test func callReturnsTheDecodedRawReturnData() async throws {
        let stub = stubbedResult("0xdeadbeef")
        let result = try await makeClient(stub).call(to: someAddress, data: Data())
        #expect(result == Data([0xDE, 0xAD, 0xBE, 0xEF]))
    }

    // MARK: - erc20Balance

    @Test func erc20BalanceSendsTheBalanceOfSelectorAndOwnerWord() async throws {
        let stub = stubbedResult(word(BigUInt(0)).hexEncoded)
        _ = try await makeClient(stub).erc20Balance(token: someAddress, owner: someOtherAddress)

        let envelope = try capturedEnvelope(stub)
        let params = try #require(envelope["params"] as? [Any])
        let callObject = try #require(params[0] as? [String: Any])
        #expect(callObject["to"] as? String == someAddress.string)

        let expectedData = EthereumABI.encodeCall(
            selector: EthereumABI.selector("balanceOf(address)"),
            parameters: [.address(someOtherAddress)]
        )
        #expect(callObject["data"] as? String == expectedData.hexEncoded)
    }

    @Test func erc20BalanceDecodesTheReturnedWordAsAUInt256() async throws {
        let balance = BigUInt(123_456_789)
        let stub = stubbedResult(word(balance).hexEncoded)
        #expect(try await makeClient(stub).erc20Balance(token: someAddress, owner: someOtherAddress) == balance)
    }

    @Test func erc20BalanceThrowsDecodingFailedOnAnEmptyResponse() async throws {
        let client = makeClient(stubbedResult("0x"))
        await #expect(throws: BlockchainClientError.self) {
            _ = try await client.erc20Balance(token: someAddress, owner: someOtherAddress)
        }
    }

    // MARK: - erc20TokenInfo

    @Test func erc20TokenInfoFetchesUSDCsMetadataFromTheLiveMainnet() async throws {
        await withKnownIssue("requires network access to a live Ethereum mainnet RPC endpoint", isIntermittent: true) {
            let client = EthereumRPCClient(endpoint: URL(string: "https://ethereum-rpc.publicnode.com")!)
            let usdc = try EthereumAddress(string: "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48")

            let info = try await client.erc20TokenInfo(token: usdc)
            #expect(info.name == "USD Coin")
            #expect(info.symbol == "USDC")
            #expect(info.decimals == 6)
        }
    }

    // MARK: - resolveENSName

    @Test func resolveENSNameReturnsTheAddressFromTheFinalAddrResponse() async throws {
        // A single stubbed response serves both the resolver(bytes32) and
        // addr(bytes32) calls (StubURLProtocol only holds one canned
        // response), so the resolved "resolver" and returned address are
        // the same value here — this only exercises the
        // decode-the-final-response path, not that the two calls
        // genuinely chain through a distinct resolver address.
        let stub = stubbedResult(word(someAddress.rawBytes).hexEncoded)
        let resolved = try await makeClient(stub).resolveENSName("vitalik.eth")
        #expect(resolved == someAddress)
    }

    @Test func resolveENSNameSendsAddrBytes32WithTheNamehashedNodeToTheResolvedResolver() async throws {
        let stub = stubbedResult(word(someAddress.rawBytes).hexEncoded)
        _ = try await makeClient(stub).resolveENSName("vitalik.eth")

        let envelope = try capturedEnvelope(stub)
        let params = try #require(envelope["params"] as? [Any])
        let callObject = try #require(params[0] as? [String: Any])
        #expect(callObject["to"] as? String == someAddress.string)

        let expectedData = EthereumABI.encodeCall(
            selector: EthereumABI.selector("addr(bytes32)"),
            parameters: [.bytes32(EthereumENS.namehash("vitalik.eth"))]
        )
        #expect(callObject["data"] as? String == expectedData.hexEncoded)
    }

    @Test func resolveENSNameThrowsDecodingFailedWhenTheResolverIsTheZeroAddress() async throws {
        let client = makeClient(stubbedResult(word(Data(repeating: 0, count: 20)).hexEncoded))
        await #expect(throws: BlockchainClientError.self) {
            _ = try await client.resolveENSName("vitalik.eth")
        }
    }

    @Test func resolveENSNameThrowsDecodingFailedOnAnEmptyResolverResponse() async throws {
        let client = makeClient(stubbedResult("0x"))
        await #expect(throws: BlockchainClientError.self) {
            _ = try await client.resolveENSName("vitalik.eth")
        }
    }

    @Test func resolveENSNameDefaultsToTheMainnetENSRegistry() async throws {
        // A zero-address resolver response makes `resolveENSName` throw
        // before it ever sends the second (addr(bytes32)) call, so the
        // captured envelope unambiguously reflects the first call — the
        // one to the ENS Registry itself.
        let stub = stubbedResult(word(Data(repeating: 0, count: 20)).hexEncoded)
        let client = makeClient(stub)
        await #expect(throws: BlockchainClientError.self) {
            _ = try await client.resolveENSName("vitalik.eth")
        }

        let envelope = try capturedEnvelope(stub)
        let params = try #require(envelope["params"] as? [Any])
        let callObject = try #require(params[0] as? [String: Any])
        #expect(callObject["to"] as? String == EthereumRPCClient.mainnetENSRegistry.string)
    }

    @Test func resolveENSNameSendsResolverBytes32ToTheProvidedENSRegistry() async throws {
        // Same zero-address-resolver trick as above, isolating the first
        // call, to confirm a caller-supplied `ensRegistry` (e.g. an L2's
        // own registry) is actually used instead of the mainnet default.
        let stub = stubbedResult(word(Data(repeating: 0, count: 20)).hexEncoded)
        let client = makeClient(stub)
        await #expect(throws: BlockchainClientError.self) {
            _ = try await client.resolveENSName("vitalik.eth", ensRegistry: someOtherAddress)
        }

        let envelope = try capturedEnvelope(stub)
        let params = try #require(envelope["params"] as? [Any])
        let callObject = try #require(params[0] as? [String: Any])
        #expect(callObject["to"] as? String == someOtherAddress.string)

        let expectedData = EthereumABI.encodeCall(
            selector: EthereumABI.selector("resolver(bytes32)"),
            parameters: [.bytes32(EthereumENS.namehash("vitalik.eth"))]
        )
        #expect(callObject["data"] as? String == expectedData.hexEncoded)
    }

    // MARK: - chainlinkFeedAddress

    @Test func chainlinkFeedAddressResolvesTheBaseDashQuoteDataEthENSName() async throws {
        let stub = stubbedResult(word(someAddress.rawBytes).hexEncoded)
        _ = try await makeClient(stub).chainlinkFeedAddress(base: "ETH", quote: "USD")

        let envelope = try capturedEnvelope(stub)
        let params = try #require(envelope["params"] as? [Any])
        let callObject = try #require(params[0] as? [String: Any])

        let expectedData = EthereumABI.encodeCall(
            selector: EthereumABI.selector("addr(bytes32)"),
            parameters: [.bytes32(EthereumENS.namehash("eth-usd.data.eth"))]
        )
        #expect(callObject["data"] as? String == expectedData.hexEncoded)
    }

    @Test func chainlinkFeedAddressLowercasesAndDefaultsTheQuoteToUSD() async throws {
        let stub = stubbedResult(word(someAddress.rawBytes).hexEncoded)
        _ = try await makeClient(stub).chainlinkFeedAddress(base: "BTC")

        let envelope = try capturedEnvelope(stub)
        let params = try #require(envelope["params"] as? [Any])
        let callObject = try #require(params[0] as? [String: Any])

        let expectedData = EthereumABI.encodeCall(
            selector: EthereumABI.selector("addr(bytes32)"),
            parameters: [.bytes32(EthereumENS.namehash("btc-usd.data.eth"))]
        )
        #expect(callObject["data"] as? String == expectedData.hexEncoded)
    }

    @Test func chainlinkFeedAddressForwardsAProvidedENSRegistry() async throws {
        // Same zero-address-resolver trick as resolveENSName's equivalent
        // test — isolates the first call to confirm chainlinkFeedAddress
        // forwards its `ensRegistry` rather than hardcoding mainnet's.
        let stub = stubbedResult(word(Data(repeating: 0, count: 20)).hexEncoded)
        let client = makeClient(stub)
        await #expect(throws: BlockchainClientError.self) {
            _ = try await client.chainlinkFeedAddress(base: "ETH", ensRegistry: someOtherAddress)
        }

        let envelope = try capturedEnvelope(stub)
        let params = try #require(envelope["params"] as? [Any])
        let callObject = try #require(params[0] as? [String: Any])
        #expect(callObject["to"] as? String == someOtherAddress.string)
    }

    // MARK: - chainlinkFeedAddress + latestRoundData (live mainnet)

    @Test(arguments: ["USDC", "USDT"])
    func chainlinkFeedPriceForAStablecoinIsWithinOnePercentOfOneDollar(symbol: String) async throws {
        await withKnownIssue("requires network access to a live Ethereum mainnet RPC endpoint", isIntermittent: true) {
            let client = EthereumRPCClient(endpoint: URL(string: "https://ethereum-rpc.publicnode.com")!)

            let feed = try await client.chainlinkFeedAddress(base: symbol, quote: "USD")
            let roundData = try await client.latestRoundData(feed: feed)

            let decimalsData = try await client.call(
                to: feed,
                data: EthereumABI.encodeCall(selector: EthereumABI.selector("decimals()"))
            )
            let decimalsWord = try #require(EthereumABI.words(decimalsData).first)
            let decimals = try #require(Int(exactly: EthereumABI.decodeUInt256(decimalsWord)))

            let price = Double(roundData.answer) / pow(10, Double(decimals))
            #expect(abs(price - 1.0) <= 0.01, "\(symbol)/USD price \(price) is not within 1% of $1")
        }
    }

    // MARK: - latestRoundData

    @Test func latestRoundDataDecodesAllFiveWords() async throws {
        let roundId = BigUInt(7)
        let answer = BigInt(-12345) // negative — exercises decodeInt256's two's-complement path.
        let startedAt = BigUInt(1_000)
        let updatedAt = BigUInt(2_000)
        let answeredInRound = BigUInt(7)

        let responseData = word(roundId) + word(answer) + word(startedAt) + word(updatedAt) + word(answeredInRound)
        let stub = stubbedResult(responseData.hexEncoded)

        let result = try await makeClient(stub).latestRoundData(feed: someAddress)
        #expect(result.roundId == roundId)
        #expect(result.answer == answer)
        #expect(result.startedAt == startedAt)
        #expect(result.updatedAt == updatedAt)
        #expect(result.answeredInRound == answeredInRound)
    }

    @Test func latestRoundDataSendsTheLatestRoundDataSelectorWithNoParameters() async throws {
        let responseData = Data(repeating: 0, count: 32 * 5)
        let stub = stubbedResult(responseData.hexEncoded)
        _ = try await makeClient(stub).latestRoundData(feed: someAddress)

        let envelope = try capturedEnvelope(stub)
        let params = try #require(envelope["params"] as? [Any])
        let callObject = try #require(params[0] as? [String: Any])
        #expect(callObject["data"] as? String == EthereumABI.selector("latestRoundData()").hexEncoded)
    }

    @Test func latestRoundDataThrowsDecodingFailedWhenFewerThanFiveWordsAreReturned() async throws {
        let tooShort = word(BigUInt(1)) + word(BigUInt(2))
        let client = makeClient(stubbedResult(tooShort.hexEncoded))
        await #expect(throws: BlockchainClientError.self) {
            _ = try await client.latestRoundData(feed: someAddress)
        }
    }

    // MARK: - uniswapV3TWAPPrice

    @Test func uniswapV3TWAPPriceThrowsWhenPeriodIsZero() async throws {
        // The zero-period guard fires before any network call, so an
        // arbitrary stub response is fine here.
        let client = makeClient(stubbedResult("0x"))
        await #expect(throws: BlockchainClientError.self) {
            _ = try await client.uniswapV3TWAPPrice(token: someAddress, pool: someOtherAddress, period: 0)
        }
    }

    // MARK: - uniswapV3TWAPPrice (live mainnet)
    //
    // `uniswapV3TWAPPrice` fires 3 concurrent `eth_call`s (token0/token1/
    // observe) and, once those resolve, 2 more (decimals for each side) —
    // the same "more concurrent calls than StubURLProtocol can give
    // distinct responses to" problem `erc20TokenInfoFetchesUSDCsMetadata
    // FromTheLiveMainnet` sidesteps by hitting a real, stable mainnet
    // contract instead. The USDC/WETH 0.05% pool is one of Uniswap V3's
    // highest-liquidity, longest-lived pools, so its token0/token1 and
    // decimals aren't going to change; only its price moves, which is why
    // the assertions below check direction/order-of-magnitude and
    // internal consistency rather than an exact value.

    @Test func uniswapV3TWAPPriceOfWETHAndUSDCAreConsistentReciprocalsInARealisticRange() async throws {
        await withKnownIssue("requires network access to a live Ethereum mainnet RPC endpoint", isIntermittent: true) {
            let client = EthereumRPCClient(endpoint: URL(string: "https://ethereum-rpc.publicnode.com")!)
            let usdc = try EthereumAddress(string: "0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48")
            let weth = try EthereumAddress(string: "0xc02aaa39b223fe8d0a0e5c4f27ead9083c756cc2")
            let pool = try EthereumAddress(string: "0x88e6a0c2ddd26feeb64f039a2c41296fcb3f5640") // USDC/WETH 0.05%

            let ethInUSDC = try await client.uniswapV3TWAPPrice(token: weth, pool: pool)
            let usdcInETH = try await client.uniswapV3TWAPPrice(token: usdc, pool: pool)

            // Broad bounds — only meant to catch a gross unit/decimal
            // error (which would be off by many orders of magnitude), not
            // to track ETH's actual price.
            #expect(ethInUSDC > 100 && ethInUSDC < 100_000, "ETH/USDC price \(ethInUSDC) is outside a realistic range")

            // The two directions are exact reciprocals of one another.
            #expect(abs(ethInUSDC * usdcInETH - 1) < 0.001)
        }
    }

    @Test func uniswapV3TWAPPriceThrowsWhenTokenIsNeitherOfThePoolsTokens() async throws {
        await withKnownIssue("requires network access to a live Ethereum mainnet RPC endpoint", isIntermittent: true) {
            let client = EthereumRPCClient(endpoint: URL(string: "https://ethereum-rpc.publicnode.com")!)
            let dai = try EthereumAddress(string: "0x6b175474e89094c44da98b954eedeac495271d0f")
            let pool = try EthereumAddress(string: "0x88e6a0c2ddd26feeb64f039a2c41296fcb3f5640") // USDC/WETH 0.05%

            await #expect(throws: BlockchainClientError.self) {
                _ = try await client.uniswapV3TWAPPrice(token: dai, pool: pool)
            }
        }
    }

    // MARK: - broadcast

    @Test func broadcastSendsTheRawTransactionHexAndReturnsTheHash() async throws {
        let txHash = "0x" + String(repeating: "ab", count: 32)
        let stub = stubbedResult(txHash)

        let signedTransaction = Data([0x01, 0x02, 0x03])
        let result = try await makeClient(stub).broadcast(signedTransaction)
        #expect(result == txHash)

        let envelope = try capturedEnvelope(stub)
        #expect(envelope["method"] as? String == "eth_sendRawTransaction")
        #expect(envelope["params"] as? [String] == [signedTransaction.hexEncoded])
    }

    @Test func broadcastThrowsRPCErrorWhenTheNodeRejectsTheTransaction() async throws {
        let body = #"{"jsonrpc":"2.0","id":1,"error":{"code":-32000,"message":"nonce too low"}}"#
        let client = makeClient(StubURLProtocol.makeSession(response: .success(body: Data(body.utf8))))

        do {
            _ = try await client.broadcast(Data([0x01]))
            Issue.record("expected broadcast(_:) to throw")
        } catch let error as BlockchainClientError {
            #expect(error == .rpcError(code: -32000, message: "nonce too low"))
        }
    }
}
