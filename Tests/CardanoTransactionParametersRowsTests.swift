import Foundation
import Testing
import WalletKit
@testable import ReefrWallet

struct CardanoTransactionParametersRowsTests {
    private func preview(
        missing: Int = 0,
        validWitnesses: Int = 0,
        paths: [CardanoSigningPath] = [CardanoSigningPath(index: 0, role: 0)]
    ) async throws -> CardanoTransactionPreview {
        let fixture = try await CardanoDappProviderFixture.make()
        let bytes = try await fixture.unsignedTransaction()

        return CardanoTransactionPreview(
            missingSignerCount: missing,
            partialSign: missing > 0,
            rawBytes: bytes,
            signingPaths: paths,
            transaction: try CardanoDappTransaction(decoding: bytes),
            validWitnessCount: validWitnesses
        )
    }

    private func value(_ label: String, in rows: [CardanoTransactionParametersView.Row]) -> String? {
        rows.first { $0.label == label }?.value
    }

    @Test func rowsFollowPenpotsOrderAndOmitWhatIsEmpty() async throws {
        let rows = CardanoTransactionParametersView.rows(for: try await preview())

        #expect(rows.map(\.label) == ["Signs with", "Inputs", "Outputs"])
        #expect(value("Signs with", in: rows) == "Payment #0")
        #expect(value("Inputs", in: rows) == "1")
        // A 1 ADA payment and the change, each with a shortened address.
        #expect(value("Outputs", in: rows)?.components(separatedBy: "\n").count == 2)
        #expect(value("Outputs", in: rows)?.hasPrefix("1 ADA → addr_test1") == true)
    }

    @Test func otherSignersAppearOnlyWhenSomeoneElseIsInvolved() async throws {
        let waiting = CardanoTransactionParametersView.rows(for: try await preview(missing: 2))
        let signed = CardanoTransactionParametersView.rows(for: try await preview(validWitnesses: 1))
        let alone = CardanoTransactionParametersView.rows(for: try await preview())

        #expect(value("Other signers", in: waiting) == "2 · sign after you")
        #expect(value("Other signers", in: signed) == "1 already signed")
        #expect(value("Other signers", in: alone) == nil)
    }

    @Test func keyNamesDistinguishPaymentChangeAndStakeKeys() {
        let names = CardanoTransactionParametersView.keyNames([
            CardanoSigningPath(index: 3, role: 0),
            CardanoSigningPath(index: 1, role: 1),
            CardanoSigningPath(index: 0, role: 2)
        ])

        #expect(names == "Payment #3, Change #1, Stake")
        #expect(CardanoMessageParametersView.keyName(.payment) == "Payment key")
        #expect(CardanoMessageParametersView.keyName(.stake) == "Stake key")
    }

    @Test func theFeeIsReadOnlyAndComesFromTheDecodedTransaction() async throws {
        let preview = try await preview()

        let fees = DappTransactionPreview.cardano(preview).fees

        #expect(fees.nativeFeeReserve == preview.transaction.fee)
    }
}
