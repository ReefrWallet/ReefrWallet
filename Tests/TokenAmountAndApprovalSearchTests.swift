// Tests of typed amounts, which must be wholly valid rather than read up to a bad character, and of
// what a search finds among approvals.

import BigInt
import Foundation
import Testing
import WalletKit
@testable import ReefrWallet

@Suite(.timeLimit(.minutes(1)))
struct TokenAmountAndApprovalSearchTests {
    private let blockchain = Blockchain.solana(.devnet)

    private var token: Token {
        Token(address: nil, blockchain: blockchain, tokenInfo: blockchain.nativeToken)
    }

    @Test(arguments: [
        ("1.5", BigUInt(1_500_000_000)),
        (".5", BigUInt(500_000_000)),
        ("2.", BigUInt(2_000_000_000)),
        (" 2 ", BigUInt(2_000_000_000))
    ])
    func validAmountsParse(text: String, lamports: BigUInt) throws {
        #expect(try token.smallestUnitAmount(from: text) == lamports)
    }

    @Test(arguments: ["", ".", "abc", "2x", "1,5", "1.5abc", "1 000", "1e3", "-1", "0", "0.0000000001"])
    func invalidAmountsAreRefused(text: String) {
        #expect(throws: ReefrError.self) {
            try token.smallestUnitAmount(from: text)
        }
    }

    /// The Unstake sheet starts from this text, and only the exact stake means a full unstake.
    @Test(arguments: [UInt64(1), 5_002_282_881, 18_446_744_073_709_551_615])
    func aStakeSurvivesTheAmountField(lamports: UInt64) throws {
        let text = "\(SolanaStakingFormat.decimalSol(lamports))"

        #expect(try token.smallestUnitAmount(from: text) == BigUInt(lamports))
    }

    @Test func searchFindsApprovalsByTokenOrSpender() async throws {
        let databaseService = try makeDatabaseService()
        let account = try await makeSolanaStakingAccount(databaseService)
        let spender = "0xAbCdEf0123456789"

        try await databaseService.replaceApprovals(
            account: account,
            updates: [ApprovalUpdate(allowance: 1, approvedAt: nil, spender: spender, token: token)]
        )

        let approval = try #require(try await databaseService.fetchApprovals(account: account).first)

        #expect(approval.matches(""))
        #expect(approval.matches("   "))
        #expect(approval.matches(token.symbol.lowercased()))
        #expect(approval.matches(token.name.uppercased()))
        #expect(approval.matches(" abcdef01 "))
        #expect(!approval.matches("no such approval"))
    }
}
