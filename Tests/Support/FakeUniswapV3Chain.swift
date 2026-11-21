// An in-memory chain answering the Uniswap V3 plugin's block, call and log
// reads, with knobs for ownership, reverts, reorgs and provider limits.

import BigInt
import Foundation
import WalletKit
@testable import ReefrWallet

final class FakeUniswapV3Chain: DefiEVMReader, @unchecked Sendable {
    struct Position {
        var feeGrowthInsideLast = UniswapV3Math.FeeGrowth(token0: 0, token1: 0)
        var liquidity: BigUInt
        var tickLower = -600
        var tickUpper = 600
        var tokensOwed = (token0: BigUInt(0), token1: BigUInt(0))
    }

    enum Ownership {
        case owner(String)
        case revert(Data)
    }

    /// Mainnet's addresses, deployed at genesis so tests can use small block numbers.
    static let deployment = UniswapV3Deployment(
        factory: "0x1f98431c8ad98523631ae4a59f267346ea31f984",
        positionManager: "0xc36442b4a4522e871399cd717abdd847ab11fe88",
        deploymentBlock: 0
    )

    // swiftlint:disable force_try
    static let pool = try! EthereumAddress(string: "0x" + String(repeating: "dd", count: 20))
    static let token0 = try! EthereumAddress(string: "0x" + String(repeating: "01", count: 20))
    static let token1 = try! EthereumAddress(string: "0x" + String(repeating: "02", count: 20))
    // swiftlint:enable force_try

    private let lock = NSLock()
    private var _head: UInt64 = 1_000
    private var _finalizedDepth: UInt64? = 10
    private var _forks: [UInt64: String] = [:]
    private var _logs: [EVMLog] = []
    private var _logCalls = 0
    private var _maxLogRange: UInt64?
    private var _ownership: [BigUInt: Ownership] = [:]
    private var _positions: [BigUInt: Position] = [:]
    private var _onHeadRead: (() -> Void)?
    var poolTick = 0
    var feeGrowthGlobal = UniswapV3Math.FeeGrowth(token0: 0, token1: 0)

    var head: UInt64 {
        get { locked { _head } }
        set { locked { _head = newValue } }
    }

    var logCalls: Int {
        locked { _logCalls }
    }

    var maxLogRange: UInt64? {
        get { locked { _maxLogRange } }
        set { locked { _maxLogRange = newValue } }
    }

    var onHeadRecheck: (() -> Void)? {
        get { locked { _onHeadRead } }
        set { locked { _onHeadRead = newValue } }
    }

    // MARK: - Setup

    func setFinalizedDepth(_ depth: UInt64?) {
        locked { _finalizedDepth = depth }
    }

    func setOwner(_ tokenId: BigUInt, _ ownership: Ownership) {
        locked { _ownership[tokenId] = ownership }
    }

    func setPosition(_ tokenId: BigUInt, _ position: Position) {
        locked { _positions[tokenId] = position }
    }

    /// Changes the hash of `block` and everything after it, dropping their logs.
    func reorg(from block: UInt64, salt: String) {
        locked {
            for number in block ... _head {
                _forks[number] = salt
            }

            _logs.removeAll { $0.blockNumber >= block }
        }
    }

    func addMint(_ tokenId: BigUInt, to owner: String, block: UInt64) {
        addLog(block: block, topics: [
            UniswapV3HistoryScanner.transferTopic,
            UniswapV3HistoryScanner.word(0),
            UniswapV3HistoryScanner.word(BigUInt(owner.dropFirst(2), radix: 16)!),
            UniswapV3HistoryScanner.word(tokenId)
        ], data: Data())
    }

    func addCollect(_ tokenId: BigUInt, _ amount0: BigUInt, _ amount1: BigUInt, block: UInt64) {
        addLog(block: block, topics: [UniswapV3HistoryScanner.collectTopic, UniswapV3HistoryScanner.word(tokenId)],
               data: Self.words([0, amount0, amount1]))
    }

    func addDecrease(_ tokenId: BigUInt, _ amount0: BigUInt, _ amount1: BigUInt, block: UInt64) {
        addLog(block: block, topics: [UniswapV3HistoryScanner.decreaseTopic, UniswapV3HistoryScanner.word(tokenId)],
               data: Self.words([1, amount0, amount1]))
    }

    func hash(_ number: UInt64) -> String {
        locked { hashLocked(number) }
    }

    // MARK: - DefiEVMReader

    func block(_ tag: BlockTag) async throws -> BlockRef? {
        let number: UInt64? = locked {
            switch tag {
            case .finalized: _finalizedDepth.map { _head > $0 ? _head - $0 : 0 }
            case .latest: _head
            case let .number(number): number <= _head ? number : nil
            }
        }

        guard let number else {
            return nil
        }

        if case .number = tag, number == head, let hook = takeHeadHook() {
            hook()
        }

        return BlockRef(
            hash: hash(number),
            number: number,
            timestamp: Date(timeIntervalSince1970: TimeInterval(number) * 12)
        )
    }

    func call(_ calls: [EVMCall], at block: BlockRef) async throws -> [EVMCallResult] {
        calls.map(answer)
    }

    func logs(address: EthereumAddress, topics: [[String]?], from: UInt64, to: UInt64) async throws -> [EVMLog] {
        try locked {
            _logCalls += 1

            if let limit = _maxLogRange, to - from + 1 > limit {
                throw BlockchainClientError.decodingFailed(reason: "range too large")
            }

            return _logs.filter { log in
                log.blockNumber >= from && log.blockNumber <= to
                    && topics.enumerated().allSatisfy { index, options in
                        options.map { index < log.topics.count && $0.contains(log.topics[index]) } ?? true
                    }
            }
        }
    }

    // MARK: - Private

    /// The plugin reads the pinned head by number only for its final recheck.
    private func takeHeadHook() -> (() -> Void)? {
        locked {
            defer { _onHeadRead = nil }
            return _onHeadRead
        }
    }

    private func addLog(block: UInt64, topics: [String], data: Data) {
        locked {
            _logs.append(EVMLog(
                blockHash: hashLocked(block),
                blockNumber: block,
                data: data,
                logIndex: UInt64(_logs.count),
                topics: topics,
                transactionHash: "0x" + String(_logs.count)
            ))
        }
    }

    private func answer(_ call: EVMCall) -> EVMCallResult {
        let selector = call.data.prefix(4)
        let argument = EthereumABI.words(Data(call.data.dropFirst(4))).first.map(EthereumABI.decodeUInt256) ?? 0

        return locked {
            switch selector {
            case EthereumABI.selector("ownerOf(uint256)"):
                switch _ownership[argument] {
                case let .owner(owner): return ok([BigUInt(owner.dropFirst(2), radix: 16)!])
                case let .revert(data): return EVMCallResult(data: data, isSuccess: false)
                case nil: return EVMCallResult(data: Data(), isSuccess: false)
                }

            case EthereumABI.selector("positions(uint256)"):
                guard let position = _positions[argument] else {
                    return EVMCallResult(data: Data(), isSuccess: false)
                }

                return ok([
                    0, 0, Self.int(Self.token0), Self.int(Self.token1), 500,
                    Self.signed(position.tickLower), Self.signed(position.tickUpper), position.liquidity,
                    position.feeGrowthInsideLast.token0, position.feeGrowthInsideLast.token1,
                    position.tokensOwed.token0, position.tokensOwed.token1
                ])
            case EthereumABI.selector("getPool(address,address,uint24)"):
                return ok([Self.int(Self.pool)])
            case EthereumABI.selector("slot0()"):
                return ok([UniswapV3Math.sqrtRatio(atTick: poolTick), Self.signed(poolTick), 0, 0, 0, 0, 1])
            case EthereumABI.selector("feeGrowthGlobal0X128()"):
                return ok([feeGrowthGlobal.token0])
            case EthereumABI.selector("feeGrowthGlobal1X128()"):
                return ok([feeGrowthGlobal.token1])
            case EthereumABI.selector("ticks(int24)"):
                return ok([1, 0, 0, 0, 0, 0, 0, 1])
            default:
                return EVMCallResult(data: Data(), isSuccess: false)
            }
        }
    }

    private func hashLocked(_ number: UInt64) -> String {
        "0x" + (_forks[number] ?? "") + String(number, radix: 16)
    }

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    private func ok(_ words: [BigUInt]) -> EVMCallResult {
        EVMCallResult(data: Self.words(words), isSuccess: true)
    }

    static func errorRevert(_ message: String) -> Data {
        EthereumABI.selector("Error(string)") + words([32, BigUInt(message.utf8.count)])
            + Data(message.utf8) + Data(repeating: 0, count: (32 - message.utf8.count % 32) % 32)
    }

    static func words(_ values: [BigUInt]) -> Data {
        values.reduce(Data()) { $0 + EthereumABI.encodeCall(selector: Data(), parameters: [.uint256($1)]) }
    }

    private static func int(_ address: EthereumAddress) -> BigUInt {
        BigUInt(address.rawBytes)
    }

    private static func signed(_ value: Int) -> BigUInt {
        value >= 0 ? BigUInt(value) : UniswapV3Math.two256 - BigUInt(-value)
    }
}

/// Fixed metadata and prices for the fake chain's two tokens.
struct FakeUniswapV3TokenSource: UniswapV3TokenSource {
    var price0: Decimal? = 2_000
    var price1: Decimal? = 1

    func tokens(
        _ addresses: [EthereumAddress],
        account: ReefrWallet.Account,
        now: Date
    ) async -> [String: UniswapV3Position.Token] {
        [
            FakeUniswapV3Chain.token0.string.lowercased(): .init(
                address: FakeUniswapV3Chain.token0.string.lowercased(), decimals: 18, imageURL: nil,
                priceAt: price0 == nil ? nil : now, symbol: "WETH", usdPrice: price0
            ),
            FakeUniswapV3Chain.token1.string.lowercased(): .init(
                address: FakeUniswapV3Chain.token1.string.lowercased(), decimals: 6, imageURL: nil,
                priceAt: price1 == nil ? nil : now, symbol: "USDC", usdPrice: price1
            )
        ]
    }
}
