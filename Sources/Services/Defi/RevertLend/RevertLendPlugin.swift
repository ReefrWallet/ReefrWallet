//
//  RevertLendPlugin.swift
//  Reefr Wallet
//
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import BigInt
import Foundation
import WalletKit

/// Revert Lend loans and deposits. Collateral positions are valued by the Uniswap V3
/// pipeline and saved as `uniswapV3` records held by the vault. See ADR-075.
struct RevertLendPlugin: DefiPlugin {
    static let kind = DefiPluginKind.revertLend

    /// A run's outcomes for both record kinds it writes.
    struct Outcomes: Sendable {
        var collateral: [DefiPositionOutcome] = []
        var lending: [DefiPositionOutcome] = []
    }

    let account: Account

    private let databaseService: DatabaseService
    private let deployments: [UInt64: RevertLendDeployment]
    private let readerFactory: @Sendable (Account) throws -> any DefiEVMReader
    private let runs = DefiRunCounter()
    private let tokenSource: any UniswapV3TokenSource
    private let uniswapDeployments: [UInt64: UniswapV3Deployment]

    init(account: Account) {
        self.init(account: account, databaseService: DI.injectOrFail(DatabaseService.self))
    }

    init(
        account: Account,
        databaseService: DatabaseService,
        deployments: [UInt64: RevertLendDeployment] = RevertLendDeployment.all,
        readerFactory: (@Sendable (Account) throws -> any DefiEVMReader)? = nil,
        tokenSource: any UniswapV3TokenSource = LiveUniswapV3TokenSource(),
        uniswapDeployments: [UInt64: UniswapV3Deployment] = UniswapV3Deployment.all
    ) {
        self.account = account
        self.databaseService = databaseService
        self.deployments = deployments
        self.readerFactory = readerFactory ?? { account in
            try IndexedLogsDefiEVMReader.live(account: account)
        }

        self.tokenSource = tokenSource
        self.uniswapDeployments = uniswapDeployments
    }

    static func isSupported(_ blockchain: Blockchain) -> Bool {
        RevertLendDeployment.deployment(for: blockchain) != nil
    }

    // MARK: - Refresh

    func refresh() async throws {
        let result = try await outcomes(
            stored: databaseService.fetchDefiPositions(account: account),
            budget: DefiRequestBudget(UniswapV3Plugin.historyBudget),
            rotation: runs.next()
        )

        try await databaseService.saveDefiOutcomes(account: account, kind: .uniswapV3, result.collateral)
        try await databaseService.saveDefiOutcomes(account: account, kind: Self.kind, result.lending)
    }

    /// Outcomes for every stored or current loan, its collateral, and the deposit.
    func outcomes(stored: [DefiPosition], budget: DefiRequestBudget, rotation: Int) async throws -> Outcomes {
        guard case let .evm(chain) = account.blockchain,
              let deployment = deployments[chain.chainId],
              let uniswap = uniswapDeployments[chain.chainId]
        else {
            return Outcomes()
        }

        let reader = try readerFactory(account)
        let blocks = try await UniswapV3Plugin.pin(reader)
        let vault = deployment.vault.string.lowercased()
        let custodian = UniswapV3Position.Custodian(kind: Self.kind, vault: vault)
        let state = try await Self.readVault(deployment, owner: account.address, reader: reader, at: blocks.pinned)
        let previous = UniswapV3Plugin.payloads(stored).filter { $0.value.custodian == custodian }
        let candidates = Self.candidates(state.tokenIds, chainId: chain.chainId)

        var result = Outcomes()

        result.collateral = try await UniswapV3Plugin.value(
            candidates,
            owner: vault,
            custodian: custodian,
            run: UniswapV3Plugin.Run(
                account: account,
                blocks: blocks,
                budget: budget,
                chainId: chain.chainId,
                deployment: uniswap,
                reader: reader,
                tokenSource: tokenSource
            ),
            previous: previous,
            mints: [:],
            rotation: rotation
        )

        result.collateral += previous.keys
            .filter { key in !candidates.contains { $0.key == key } }
            .map { .removed(key: $0) }

        let tokens = await tokenSource.tokens([deployment.asset], account: account, now: blocks.pinned.timestamp)
        result.lending = lending(
            state,
            asset: tokens[deployment.asset.string.lowercased()],
            positions: collateralPositions(result.collateral, previous: previous),
            chainId: chain.chainId,
            vault: vault,
            stored: stored
        )

        try await UniswapV3Plugin.verifyCanonical(blocks.pinned, reader: reader)
        return result
    }

    // MARK: - Private

    /// The vault's position NFTs; they have no ledger mint in the account.
    private static func candidates(_ tokenIds: [BigUInt], chainId: UInt64) -> [UniswapV3Plugin.Candidate] {
        tokenIds.map { tokenId in
            UniswapV3Plugin.Candidate(
                key: UniswapV3Plugin.key(chainId: chainId, tokenId: tokenId),
                nftKey: "",
                tokenId: tokenId
            )
        }
    }

    /// This run's collateral payloads, else the stored ones.
    private func collateralPositions(
        _ outcomes: [DefiPositionOutcome],
        previous: [String: UniswapV3Position]
    ) -> [String: UniswapV3Position] {
        outcomes.reduce(into: previous) { result, outcome in
            if case let .updated(record) = outcome {
                result[record.key] = try? record.payload.decoded() as UniswapV3Position
            }
        }
    }

    private func lending(
        _ state: VaultState,
        asset: UniswapV3Position.Token?,
        positions: [String: UniswapV3Position],
        chainId: UInt64,
        vault: String,
        stored: [DefiPosition]
    ) -> [DefiPositionOutcome] {
        let storedKeys = Set(stored.filter { $0.kind == Self.kind }.map(\.key))
        let borrowAPR = state.borrowRateX64.map(Self.annualRate(perSecondX64:))
        var outcomes: [DefiPositionOutcome] = []
        var current: Set<String> = []

        for tokenId in state.tokenIds {
            let key = RevertLendPosition.Loan.key(chainId: chainId, tokenId: tokenId)
            current.insert(key)

            guard let asset,
                  let info = state.loans[tokenId],
                  let position = positions[UniswapV3Plugin.key(chainId: chainId, tokenId: tokenId)]
            else {
                outcomes.append(.failed(key: key))
                continue
            }

            let loan = RevertLendPosition.Loan(
                asset: asset,
                borrowAPR: borrowAPR,
                chainId: chainId,
                collateralValue: String(info.collateralValue),
                debt: String(info.debt),
                fee: position.fee,
                fullValue: String(info.fullValue),
                liquidationCost: String(info.liquidationCost),
                token0: position.token0,
                token1: position.token1,
                tokenId: String(tokenId),
                vault: vault
            )

            outcomes.append(RevertLendPosition.loan(loan).record.map { .updated($0) } ?? .failed(key: key))
        }

        if state.lent > 0 {
            current.insert(RevertLendPosition.depositKey)

            if let asset {
                let deposit = RevertLendPosition.Deposit(
                    amount: String(state.lent),
                    asset: asset,
                    supplyAPR: state.supplyRateX64.map(Self.annualRate(perSecondX64:)),
                    vault: vault
                )

                outcomes.append(
                    RevertLendPosition.deposit(deposit).record.map { .updated($0) }
                        ?? .failed(key: RevertLendPosition.depositKey)
                )
            } else {
                outcomes.append(.failed(key: RevertLendPosition.depositKey))
            }
        }

        return outcomes + storedKeys.subtracting(current).map { .removed(key: $0) }
    }
}
