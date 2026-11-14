// A Jetton transfer's fee comes from emulating its trace: the Gram to hold is the reserve, the cost after the
// refund is shown separately, and an unavailable emulation falls back to the fixed budget (ADR-071).

import BigInt
import Foundation
import Testing
import WalletKit
@testable import ReefrWallet

struct TonFeeEstimationTests {
    private struct Offline: Error {}

    /// A transaction attaching `attachment`, as the builder would build it for that step.
    private func build(_ attachment: BigUInt) -> TonUnsignedTransaction {
        TonUnsignedTransaction(
            body: Data(),
            network: .testnet,
            recipient: "r",
            sender: "s",
            seqno: 1,
            stateInit: nil,
            validUntil: 2,
            value: String(attachment)
        )
    }

    /// An emulation that credits only when at least `needed` is attached.
    private func quote(needing needed: BigUInt) -> (TonUnsignedTransaction) async throws -> TonSendQuote {
        { transaction in
            let attached = BigUInt(transaction.value) ?? 0
            return TonSendQuote(
                upfront: attached + 616_123,
                net: 27_703_001,
                expectedToFail: attached < needed,
                creditSeen: attached >= needed
            )
        }
    }

    @Test func theSmallestAttachmentThatCreditsIsKeptWithItsReserveAndNetCost() async throws {
        let fees = try await FeeEstimationService.jettonFees(build: build, quote: quote(needing: 100_000_000))
        #expect(fees.tonAttachment == "100000000")
        #expect(fees.nativeFeeReserve == "100616123")
        #expect(fees.tonNetCost == "27703001")

        let first = try await FeeEstimationService.jettonFees(build: build, quote: quote(needing: 1))
        #expect(first.tonAttachment == "50000000")
    }

    @Test func aTransferNoAttachmentCanCreditIsNotQuoted() async {
        await #expect(throws: TonSendError.wouldFail) {
            _ = try await FeeEstimationService.jettonFees(build: build, quote: quote(needing: BigUInt(10).power(30)))
        }
    }

    @Test func anInconclusiveEmulationKeepsTheAttachmentItWasTriedWith() async throws {
        let fees = try await FeeEstimationService.jettonFees(build: build) { _ in
            TonSendQuote(upfront: 50_616_123, net: nil, expectedToFail: false)
        }

        #expect(fees.tonAttachment == "50000000")
        #expect(fees.tonNetCost == nil)
    }

    @Test func unavailableEmulationFallsBackToTheFixedBudgetWithoutANetCost() async throws {
        let fees = try await FeeEstimationService.jettonFees(build: build) { _ in throw Offline() }
        #expect(fees.nativeFeeReserve == String(BigUInt(50_000_000) + TonTransactionBuilder.jettonFeeReserve))
        #expect(fees.tonNetCost == nil)
        #expect(fees.tonAttachment == nil)
    }

    @Test func aTimeoutAfterARefusedAttachmentDoesNotRestoreIt() async {
        await #expect(throws: TonSendError.attachmentUndetermined) {
            _ = try await FeeEstimationService.jettonFees(build: build) { transaction in
                guard (BigUInt(transaction.value) ?? 0) > 50_000_000 else {
                    return TonSendQuote(upfront: 1, net: nil, expectedToFail: true)
                }

                throw Offline()
            }
        }
    }

    @Test func anyBuilderErrorReachesTheCallerNotTheFallback() async {
        await #expect(throws: WalletKitError.self) {
            _ = try await FeeEstimationService.jettonFees(
                build: { _ in throw WalletKitError.invalidAddress(reason: "key") },
                quote: { _ in throw Offline() }
            )
        }
    }

    @Test func aBuilderRefusalIsNotMistakenForUnavailableEmulation() async {
        await #expect(throws: BlockchainTransactionBuilderError.self) {
            _ = try await FeeEstimationService.jettonFees(
                build: { _ in throw BlockchainTransactionBuilderError.insufficientFunds(reason: "tokens") },
                quote: { _ in TonSendQuote(upfront: 0, net: nil, expectedToFail: false) }
            )
        }
    }

    @Test func theQuotedGramBecomesTheSendsRequirementInsteadOfTheFixedReserve() throws {
        let options = try Fees(nativeFeeReserve: "100616123", tonAttachment: "100000000").tonBuilderOptions()
        #expect(options.count == 2)

        guard case let .tonRequiredGram(required)? = options.first,
              case let .tonJettonAttachment(attachment)? = options.last
        else {
            Issue.record("Expected the quoted requirement and attachment.")
            return
        }

        #expect(required == 100_616_123)
        #expect(attachment == 100_000_000)
        #expect(try Fees().tonBuilderOptions().isEmpty)
    }
}
