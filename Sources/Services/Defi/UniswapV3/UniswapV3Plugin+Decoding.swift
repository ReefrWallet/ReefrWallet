//
//  UniswapV3Plugin+Decoding.swift
//  Reefr Wallet
//
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import BigInt
import Foundation
import WalletKit

// MARK: - Decoding

extension UniswapV3Plugin {
    enum Ownership: Equatable {
        case failed
        case owned
        case removed
    }

    /// Only a decoded other owner or the manager's own nonexistent-token revert is proof of removal.
    static func ownership(_ result: EVMCallResult, owner: String) -> Ownership {
        guard result.isSuccess else {
            return result.revertReason == nonexistentTokenReason ? .removed : .failed
        }

        guard result.data.count == 32, let address = try? EthereumABI.decodeAddress(result.data) else {
            return .failed
        }

        if address == .zero {
            return .failed
        }

        return address.string.lowercased() == owner.lowercased() ? .owned : .removed
    }

    static func decodePosition(_ result: EVMCallResult) -> RawPosition? {
        let words = EthereumABI.words(result.data)

        guard result.isSuccess, words.count >= 12,
              let token0 = try? EthereumABI.decodeAddress(words[2]),
              let token1 = try? EthereumABI.decodeAddress(words[3]),
              let fee = UInt32(exactly: EthereumABI.decodeUInt256(words[4])),
              let tickLower = Int(exactly: EthereumABI.decodeInt256(words[5])),
              let tickUpper = Int(exactly: EthereumABI.decodeInt256(words[6]))
        else {
            return nil
        }

        return RawPosition(
            fee: fee,
            feeGrowthInsideLast: .init(
                token0: EthereumABI.decodeUInt256(words[8]),
                token1: EthereumABI.decodeUInt256(words[9])
            ),
            liquidity: EthereumABI.decodeUInt256(words[7]),
            tickLower: tickLower,
            tickUpper: tickUpper,
            token0: token0,
            token1: token1,
            tokensOwed: .init(EthereumABI.decodeUInt256(words[10]), EthereumABI.decodeUInt256(words[11]))
        )
    }

    static func decodePool(_ results: [EVMCallResult]) -> PoolState? {
        guard results.count == 3, results.allSatisfy(\.isSuccess) else {
            return nil
        }

        let slot0 = EthereumABI.words(results[0].data)

        guard slot0.count >= 2,
              let tick = Int(exactly: EthereumABI.decodeInt256(slot0[1])),
              let global0 = EthereumABI.words(results[1].data).first,
              let global1 = EthereumABI.words(results[2].data).first
        else {
            return nil
        }

        return PoolState(
            feeGrowthGlobal: .init(
                token0: EthereumABI.decodeUInt256(global0),
                token1: EthereumABI.decodeUInt256(global1)
            ),
            sqrtPrice: EthereumABI.decodeUInt256(slot0[0]),
            tick: tick
        )
    }

    static func decodeTickOutside(_ result: EVMCallResult) -> UniswapV3Math.FeeGrowth? {
        let words = EthereumABI.words(result.data)

        guard result.isSuccess, words.count >= 4 else {
            return nil
        }

        return .init(token0: EthereumABI.decodeUInt256(words[2]), token1: EthereumABI.decodeUInt256(words[3]))
    }

    static func encode(_ signature: String, _ tokenId: BigUInt) -> Data {
        EthereumABI.encodeCall(selector: EthereumABI.selector(signature), parameters: [.uint256(tokenId)])
    }

    /// `ticks(int24)` with the tick as a two's-complement word.
    static func encodeTick(_ tick: Int) -> Data {
        let word = tick >= 0 ? BigUInt(tick) : UniswapV3Math.two256 - BigUInt(-tick)
        return EthereumABI.encodeCall(selector: EthereumABI.selector("ticks(int24)"), parameters: [.uint256(word)])
    }
}
