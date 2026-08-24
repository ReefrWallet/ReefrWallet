import Foundation
import Testing
@testable import ReefrWallet

struct Tests {
    @Test
    func listMoralisListERC20BalancesForVitalik() async throws {
        let apiKey = try #require(
            ProcessInfo.processInfo.environment["MORALIS_API_KEY"],
            "Set MORALIS_API_KEY to run the Moralis integration test."
        )

        let accountService = AccountService()
        let keyStore = KeyStore(deviceId: nil, kind: .watchOnly, name: "", rawKey: nil, transport: nil, vendor: nil)
        let account = try await accountService.makeAccount(
            .evm(.ethereum(.mainnet)),
            keyStore: keyStore,
            watchOnlyAddress: "0xd8da6bf26964af9d7eed9e03e53415d37aa96045"
        )

        let service = MoralisService(apiKey: apiKey)
        let response = try await service.listERC20Balances(
            account: account,
            tokens: nil,
            pageCursor: nil
        )

        #expect(response.result != nil)
        #expect(response.result?.isEmpty == false)
    }
}
