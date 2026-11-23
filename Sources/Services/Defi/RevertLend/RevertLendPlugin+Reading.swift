//
//  RevertLendPlugin+Reading.swift
//  Reefr Wallet
//
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import BigInt
import Foundation
import WalletKit

// MARK: - Reading

extension RevertLendPlugin {
    static let secondsPerYear = BigUInt(31_536_000)

    /// The vault as the account sees it at one block.
    struct VaultState: Sendable {
        let borrowRateX64: BigUInt?
        /// USDC the account lent, with interest.
        let lent: BigUInt
        /// `loanInfo` by token id; missing when its read failed.
        let loans: [BigUInt: LoanInfo]
        let supplyRateX64: BigUInt?
        /// Every token id the account has in the vault, in `loanAtIndex` order.
        let tokenIds: [BigUInt]
    }

    struct LoanInfo: Sendable {
        let collateralValue: BigUInt
        let debt: BigUInt
        let fullValue: BigUInt
        let liquidationCost: BigUInt
    }

    /// The account's loans and deposit in three Multicall rounds. Throws unless the loan
    /// list itself is read, so a run never mistakes a failed read for a closed loan.
    static func readVault(
        _ deployment: RevertLendDeployment,
        owner: String,
        reader: any DefiEVMReader,
        at block: BlockRef
    ) async throws -> VaultState {
        let vault = deployment.vault
        let owner = try EthereumAddress(string: owner)
        let first = try await reader.call(
            [
                EVMCall(data: encode("loanCount(address)", [.address(owner)]), target: vault),
                EVMCall(data: encode("lendInfo(address)", [.address(owner)]), target: vault),
                EVMCall(data: encode("vaultInfo()", []), target: vault)
            ],
            at: block
        )

        guard let count = uint(first[0], word: 0), let lent = uint(first[1], word: 0) else {
            throw BlockchainClientError.decodingFailed(reason: "Revert Lend loanCount/lendInfo")
        }

        let vaultDebt = uint(first[2], word: 0)
        let vaultBalance = uint(first[2], word: 2)
        let indexes = (0 ..< Int(count)).map { BigUInt($0) }
        var calls = indexes.map { index in
            EVMCall(data: encode("loanAtIndex(address,uint256)", [.address(owner), .uint256(index)]), target: vault)
        }

        if let vaultDebt, let vaultBalance {
            calls.append(
                EVMCall(
                    data: encode(
                        "getRatesPerSecondX64(uint256,uint256)",
                        [.uint256(vaultBalance), .uint256(vaultDebt)]
                    ),
                    target: deployment.interestRateModel
                )
            )
        }

        let second = try await reader.call(calls, at: block)
        let tokenIds = try indexes.indices.map { index in
            guard let tokenId = uint(second[index], word: 0) else {
                throw BlockchainClientError.decodingFailed(reason: "Revert Lend loanAtIndex \(index)")
            }

            return tokenId
        }

        let rates = second.count > tokenIds.count ? second[tokenIds.count] : nil

        return VaultState(
            borrowRateX64: rates.flatMap { uint($0, word: 0) },
            lent: lent,
            loans: try await readLoans(tokenIds, vault: vault, reader: reader, at: block),
            supplyRateX64: rates.flatMap { uint($0, word: 1) },
            tokenIds: tokenIds
        )
    }

    /// A per-second X64 rate as a yearly fraction, to six fraction digits.
    static func annualRate(perSecondX64 rate: BigUInt) -> Decimal {
        let micros = (rate * secondsPerYear * 1_000_000) >> 64
        return Decimal(sign: .plus, exponent: -6, significand: Decimal(string: micros.description) ?? 0)
    }

    // MARK: - Private

    /// Round 3: `loanInfo` per token.
    private static func readLoans(
        _ tokenIds: [BigUInt],
        vault: EthereumAddress,
        reader: any DefiEVMReader,
        at block: BlockRef
    ) async throws -> [BigUInt: LoanInfo] {
        guard !tokenIds.isEmpty else {
            return [:]
        }

        let calls = tokenIds.map { EVMCall(data: encode("loanInfo(uint256)", [.uint256($0)]), target: vault) }
        let returned = try await reader.call(calls, at: block)
        var loans: [BigUInt: LoanInfo] = [:]

        for (tokenId, result) in zip(tokenIds, returned) {
            guard let debt = uint(result, word: 0),
                  let fullValue = uint(result, word: 1),
                  let collateralValue = uint(result, word: 2),
                  let liquidationCost = uint(result, word: 3)
            else {
                continue
            }

            loans[tokenId] = LoanInfo(
                collateralValue: collateralValue,
                debt: debt,
                fullValue: fullValue,
                liquidationCost: liquidationCost
            )
        }

        return loans
    }

    private static func encode(_ signature: String, _ parameters: [EthereumABIValue]) -> Data {
        EthereumABI.encodeCall(selector: EthereumABI.selector(signature), parameters: parameters)
    }

    /// Word `word` of a successful result as uint256.
    private static func uint(_ result: EVMCallResult, word: Int) -> BigUInt? {
        let words = EthereumABI.words(result.data)

        guard result.isSuccess, words.count > word else {
            return nil
        }

        return EthereumABI.decodeUInt256(words[word])
    }
}
