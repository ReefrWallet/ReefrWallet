//
//  WalletConnectChainTests.swift
//  Reefr Wallet
//
//  Created by Andrey Yurkevich on 17.10.26.
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import Testing
import WalletKit

@testable import ReefrWallet

@Suite
struct WalletConnectChainTests {
    @Test(arguments: [
        "aptos:1", "eip155:1", "eip155:137", "solana:5eykt4UsFv8P8NJdTREpY1vzqKqZKvdp", "sui:mainnet", "tron:0x2b6653dc"
    ])
    func caipRoundTrips(chain: String) throws {
        let blockchain = try #require(WalletConnectChain.blockchain(caip2: chain))
        #expect(WalletConnectChain.caip2(for: blockchain) == chain)
    }

    @Test
    func mapsChainsToNamespaces() {
        #expect(WalletConnectChain.dappNamespace(caip2: "eip155:10") == .ethereum)
        #expect(WalletConnectChain.dappNamespace(caip2: "tron:0x2b6653dc") == .tron)
        #expect(WalletConnectChain.dappNamespace(caip2: "cosmos:hub") == nil)
        #expect(WalletConnectChain.blockchain(caip2: "eip155:abc") == nil)
    }

    @Test
    func extractsPairingURIFromDeepLink() {
        let link = "reefr://wc?uri=wc%3Aabc%402%3Frelay-protocol%3Dirn%26symKey%3Dkey"
        #expect(WalletConnectService.pairingURI(from: link) == "wc:abc@2?relay-protocol=irn&symKey=key")
        #expect(WalletConnectService.pairingURI(from: " wc:abc@2 ") == "wc:abc@2")
    }
}
