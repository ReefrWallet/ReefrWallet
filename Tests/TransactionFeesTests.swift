// Unit tests for the fee conversions behind the unified send/sign sheet
// (ADR-042): gwei editing over wei `Fees`, and the read-only Solana fee
// derived from a dapp transaction's Compute Budget instructions.

import Foundation
import Testing
import WalletKit
@testable import ReefrWallet

@Suite(.timeLimit(.minutes(1)))
struct TransactionFeesTests {
    @Test
    func formatsWeiAsGwei() {
        #expect(Gwei.string(fromWei: "26300000000") == "26.3")
        #expect(Gwei.string(fromWei: "1500000000") == "1.5")
        #expect(Gwei.string(fromWei: "1") == "0.000000001")
        #expect(Gwei.string(fromWei: "0") == "0")
        #expect(Gwei.string(fromWei: "-1") == nil)
    }

    @Test
    func parsesGweiAsWei() {
        #expect(Gwei.wei(fromGwei: "26.3") == BigUInt(26_300_000_000))
        #expect(Gwei.wei(fromGwei: "2") == BigUInt(2_000_000_000))
        #expect(Gwei.wei(fromGwei: "0.000000001") == BigUInt(1))
    }

    @Test
    func rejectsGweiTheWeiFieldsCannotHold() {
        for text in ["", ".", "1.", ".5", "1.2.3", "-1", "1e9", "0.0000000001", "1,5", "١"] {
            #expect(Gwei.wei(fromGwei: text) == nil, "\(text)")
        }
    }

    @Test
    func roundTripsWei() {
        for wei in ["0", "1", "999999999", "1000000000", "123456789012345678901"] {
            #expect(Gwei.string(fromWei: wei).flatMap(Gwei.wei(fromGwei:))?.description == wei)
        }
    }

    @Test
    func solanaFeeIsSignaturesOnlyWithoutPriceInstruction() {
        let budget = SolanaComputeBudget(instructionCount: 2, unitLimit: nil, unitPrice: nil)
        #expect(budget.maxFee(signatureCount: 2) == 10_000)
    }

    /// 1,000 µLamports × 200,000 units = 200 lamports on top of one signature.
    @Test
    func solanaPriorityFeeUsesTheRequestedLimit() {
        let budget = SolanaComputeBudget(instructionCount: 3, unitLimit: 200_000, unitPrice: 1_000)
        #expect(budget.maxFee(signatureCount: 1) == 5_200)
    }

    /// Without a limit each non-budget instruction gets 200,000 units; the
    /// priority fee rounds up to a whole lamport.
    @Test
    func solanaPriorityFeeDefaultsPerInstructionAndRoundsUp() {
        let budget = SolanaComputeBudget(instructionCount: 2, unitLimit: nil, unitPrice: 1)
        #expect(budget.units == 400_000)
        #expect(budget.maxFee(signatureCount: 1) == 5_001)
    }

    @Test
    func solanaPriorityFeeSaturatesInsteadOfTrapping() {
        let budget = SolanaComputeBudget(instructionCount: 1, unitLimit: .max, unitPrice: .max)
        #expect(budget.units == SolanaComputeBudget.maxUnits)
        #expect(budget.maxFee(signatureCount: 1) == .max)
    }
}
