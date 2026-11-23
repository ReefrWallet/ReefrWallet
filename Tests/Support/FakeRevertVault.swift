// A Revert Lend vault and interest rate model in front of the fake Uniswap V3
// chain: vault calls are answered here, the rest by the chain (ADR-075).

import BigInt
import Foundation
import WalletKit
@testable import ReefrWallet

final class FakeRevertVault: DefiEVMReader, @unchecked Sendable {
    struct Loan {
        var collateralValue: BigUInt
        var debt: BigUInt
        var fullValue: BigUInt
    }

    /// Mainnet's vault, lending the fake chain's USDC.
    static let deployment = RevertLendDeployment(
        asset: FakeUniswapV3Chain.token1.string,
        interestRateModel: "0xb50dafe03fee68595ab2baad3c16f899421f063b",
        vault: "0xa2754543f69dc036764bbfad16d2a74f5cd15667"
    )

    static var vault: String {
        deployment.vault.string.lowercased()
    }

    let chain = FakeUniswapV3Chain()

    private let lock = NSLock()
    private var _brokenLoans: Set<BigUInt> = []
    private var _lent: BigUInt = 0
    private var _loans: [(tokenId: BigUInt, loan: Loan)] = []

    /// 8% a year.
    static let borrowRateX64 = (BigUInt(8) << 64) / 100 / BigUInt(31_536_000)
    /// 5% a year.
    static let supplyRateX64 = (BigUInt(5) << 64) / 100 / BigUInt(31_536_000)

    // MARK: - Setup

    /// A vault-held, in-range position with `loan`.
    func addLoan(_ tokenId: BigUInt, _ loan: Loan) {
        chain.setOwner(tokenId, .owner(Self.vault))
        chain.setPosition(tokenId, .init(liquidity: 1_000_000_000_000))
        locked { _loans.append((tokenId, loan)) }
    }

    func breakLoanInfo(_ tokenId: BigUInt) {
        locked { _ = _brokenLoans.insert(tokenId) }
    }

    func removeLoan(_ tokenId: BigUInt, to owner: String) {
        chain.setOwner(tokenId, .owner(owner))
        locked { _loans.removeAll { $0.tokenId == tokenId } }
    }

    func setLent(_ amount: BigUInt) {
        locked { _lent = amount }
    }

    // MARK: - DefiEVMReader

    func block(_ tag: BlockTag) async throws -> BlockRef? {
        try await chain.block(tag)
    }

    func call(_ calls: [EVMCall], at block: BlockRef) async throws -> [EVMCallResult] {
        var results: [EVMCallResult] = []

        for call in calls {
            if let answer = answer(call) {
                results.append(answer)
            } else {
                results += try await chain.call([call], at: block)
            }
        }

        return results
    }

    func logs(address: EthereumAddress, topics: [[String]?], from: UInt64, to: UInt64) async throws -> [EVMLog] {
        try await chain.logs(address: address, topics: topics, from: from, to: to)
    }

    // MARK: - Private

    private func answer(_ call: EVMCall) -> EVMCallResult? {
        let deployment = Self.deployment

        guard call.target == deployment.vault || call.target == deployment.interestRateModel else {
            return nil
        }

        let selector = call.data.prefix(4)
        let words = EthereumABI.words(Data(call.data.dropFirst(4))).map(EthereumABI.decodeUInt256)

        return locked {
            switch selector {
            case EthereumABI.selector("loanCount(address)"):
                return ok([BigUInt(_loans.count)])
            case EthereumABI.selector("lendInfo(address)"):
                return ok([_lent])
            case EthereumABI.selector("vaultInfo()"):
                return ok([1_000_000, 5_000_000, 4_000_000, 0, 0, 0])
            case EthereumABI.selector("loanAtIndex(address,uint256)"):
                return words.count == 2 && Int(words[1]) < _loans.count ? ok([_loans[Int(words[1])].tokenId]) : nil
            case EthereumABI.selector("loanInfo(uint256)"):
                guard let tokenId = words.first,
                      !_brokenLoans.contains(tokenId),
                      let loan = _loans.first(where: { $0.tokenId == tokenId })?.loan
                else {
                    return EVMCallResult(data: Data(), isSuccess: false)
                }

                return ok([loan.debt, loan.fullValue, loan.collateralValue, 0, 0])
            case EthereumABI.selector("getRatesPerSecondX64(uint256,uint256)"):
                return ok([Self.borrowRateX64, Self.supplyRateX64])
            default:
                return EVMCallResult(data: Data(), isSuccess: false)
            }
        }
    }

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    private func ok(_ words: [BigUInt]) -> EVMCallResult {
        EVMCallResult(data: FakeUniswapV3Chain.words(words), isSuccess: true)
    }
}
