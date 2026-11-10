// The app's price/identity rate-limit check follows WalletKit's quota classification.

import Testing
import WalletKit
@testable import ReefrWallet

struct QuotaErrorTests {
    @Test func aTransportClassifiedQuotaErrorIsRateLimited() {
        let error = BlockchainClientError.quotaExceeded(code: -32005, message: "limit", retryAfter: .seconds(2))

        #expect(error.isRateLimited)
    }

    @Test func anInfuraResultCapIsNotRateLimited() {
        let error = BlockchainClientError.rpcError(code: -32005, message: "query returned more than 10000 results")

        #expect(!error.isRateLimited)
    }
}
