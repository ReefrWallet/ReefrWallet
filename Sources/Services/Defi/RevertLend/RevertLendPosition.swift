//
//  RevertLendPosition.swift
//  Reefr Wallet
//
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import BigInt
import Foundation

/// The stored payload of a Revert Lend loan or deposit. See ADR-075.
enum RevertLendPosition: Codable, Equatable, Sendable {
    case deposit(Deposit)
    case loan(Loan)

    static let depositKey = "deposit"

    /// USDC lent to the vault, with interest.
    struct Deposit: Codable, Equatable, Sendable {
        /// In `asset` base units.
        let amount: String
        let asset: UniswapV3Position.Token
        let supplyAPR: Decimal?
        let vault: String

        var amountValue: BigUInt {
            BigUInt(amount) ?? 0
        }
    }

    /// A loan against a Uniswap V3 position; the position itself is a `uniswapV3` record.
    struct Loan: Codable, Equatable, Sendable {
        let asset: UniswapV3Position.Token
        let borrowAPR: Decimal?
        let chainId: UInt64
        /// Position value after collateral factors, in `asset` base units.
        let collateralValue: String
        /// In `asset` base units.
        let debt: String
        let fee: UInt32
        /// Position value, in `asset` base units.
        let fullValue: String
        /// What a liquidator would pay now, in `asset` base units; 0 while healthy.
        let liquidationCost: String
        let token0: UniswapV3Position.Token
        let token1: UniswapV3Position.Token
        let tokenId: String
        let vault: String

        var collateralValueAmount: BigUInt {
            BigUInt(collateralValue) ?? 0
        }

        var debtAmount: BigUInt {
            BigUInt(debt) ?? 0
        }

        var fullValueAmount: BigUInt {
            BigUInt(fullValue) ?? 0
        }

        /// Collateral value ÷ debt; below 1 the loan can be liquidated. `nil` without debt.
        var health: Decimal? {
            guard debtAmount > 0 else {
                return nil
            }

            return asset.decimalAmount(collateralValueAmount) / asset.decimalAmount(debtAmount)
        }

        /// Debt ÷ position value.
        var loanToValue: Decimal? {
            guard fullValueAmount > 0 else {
                return nil
            }

            return asset.decimalAmount(debtAmount) / asset.decimalAmount(fullValueAmount)
        }

        static func key(chainId: UInt64, tokenId: BigUInt) -> String {
            "loan:\(chainId):\(tokenId)"
        }
    }

    var key: String {
        switch self {
        case .deposit:
            Self.depositKey
        case let .loan(loan):
            Loan.key(chainId: loan.chainId, tokenId: BigUInt(loan.tokenId) ?? 0)
        }
    }

    /// The deposit, or minus the debt: the collateral counts in its `uniswapV3` record.
    var usdValue: Decimal {
        switch self {
        case let .deposit(deposit):
            deposit.asset.usdValue(deposit.amountValue) ?? 0
        case let .loan(loan):
            -(loan.asset.usdValue(loan.debtAmount) ?? 0)
        }
    }

    var record: DefiPositionRecord? {
        (try? encoded()).map { DefiPositionRecord(key: key, payload: $0, usdValue: usdValue) }
    }
}
