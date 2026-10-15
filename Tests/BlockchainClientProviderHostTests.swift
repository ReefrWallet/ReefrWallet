// Unit tests for BlockchainClientProvider's host matching, which decides
// whether an RPC override still counts as the chain's own infrastructure —
// and so whether the user's API key is sent to it.

import Foundation
import Testing
@testable import ReefrWallet

@Suite(.timeLimit(.minutes(1)))
struct BlockchainClientProviderHostTests {
    @Test
    func matchesTheDomainAndItsSubdomains() {
        #expect(BlockchainClientProvider.isHost("aptoslabs.com", within: "aptoslabs.com"))
        #expect(BlockchainClientProvider.isHost("api.mainnet.aptoslabs.com", within: "aptoslabs.com"))
        #expect(BlockchainClientProvider.isHost("API.Aptoslabs.COM", within: "aptoslabs.com"))
    }

    /// `hasSuffix` alone matches a domain an attacker can register.
    @Test
    func rejectsLookalikeDomains() {
        #expect(BlockchainClientProvider.isHost("notaptoslabs.com", within: "aptoslabs.com") == false)
        #expect(BlockchainClientProvider.isHost("evil-aptoslabs.com", within: "aptoslabs.com") == false)
        #expect(BlockchainClientProvider.isHost("aptoslabs.com.evil.example", within: "aptoslabs.com") == false)
        #expect(BlockchainClientProvider.isHost(nil, within: "aptoslabs.com") == false)
    }
}
