// Spec-driven test for Docs/Design Specification/ChainClients/HardwareChainSigner.swift.
// Will compile once the corresponding type is exported from Sources.
//
// No (chain, vendor) signer exists yet, so this exercises the protocol's
// shape through a local mock. Requires a connected (or mocked) Trezor to
// obtain a real `HardwareDevice`; `#require` skips cleanly when none is
// available rather than crashing.

import Testing
@testable import WalletKit

private struct MockHardwareChainSigner: HardwareChainSigner {
    typealias UnsignedTransaction = String
    typealias SignedTransaction = String

    let signHandler: (String, Account, HardwareDevice) async throws -> String

    func sign(_ transaction: String, account: Account, device: HardwareDevice) async throws -> String {
        try await signHandler(transaction, account, device)
    }
}

struct HardwareChainSignerTests {
    @Test func signForwardsTheTransactionAccountAndDevice() async throws {
        let manager = HardwareDeviceManager()
        let devices = try await manager.scan()
        let info = try #require(devices.first, "requires a connected test device")
        let device = try await manager.connect(info, delegate: RecordingHardwareDeviceDelegate())
        let account = try await device.account(.bitcoin)

        var receivedTransaction: String?
        let signer = MockHardwareChainSigner { transaction, _, _ in
            receivedTransaction = transaction
            return "signed:\(transaction)"
        }

        let signed = try await signer.sign("unsigned-tx", account: account, device: device)
        #expect(signed == "signed:unsigned-tx")
        #expect(receivedTransaction == "unsigned-tx")
    }
}
