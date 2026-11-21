// NFT snapshot commits: listing replacement, ledger overlap/reorg handling,
// per-source cursors and fallback, metadata and pending sends (ADR-072).

import BigInt
import Foundation
import Testing
import WalletKit
@testable import ReefrWallet

@Suite(.timeLimit(.minutes(1)))
struct NFTStoreTests {
    private static let owner = "0x" + String(repeating: "aa", count: 20)
    private static let other = "0x" + String(repeating: "bb", count: 20)
    private static let contract = "0x" + String(repeating: "cc", count: 20)
    private static let zero = "0x" + String(repeating: "00", count: 20)

    private func evmAccount(_ databaseService: DatabaseService) async throws -> ReefrWallet.Account {
        try await makeStakingAccount(databaseService, blockchain: .evm(.ethereum(.mainnet)), address: Self.owner)
    }

    private func event(
        _ source: NFTSourceId,
        from: String,
        to: String,
        id: String = "1",
        block: UInt64,
        hash: String
    ) -> NFTTransferEvent {
        NFTTransferEvent(
            amount: 1,
            batchPosition: 0,
            blockHash: nil,
            blockNumber: block,
            contract: Self.contract,
            from: from,
            logIndex: 0,
            source: source.rawValue,
            standard: .erc721,
            to: to,
            tokenId: id,
            transactionIndex: 0,
            txHash: hash
        )
    }

    private func ledger(
        _ source: NFTSourceId,
        _ events: [NFTTransferEvent],
        from: UInt64,
        scanned: UInt64
    ) -> NFTLedgerScan {
        NFTLedgerScan(events: events, fromBlock: from, metadata: [:], scannedBlock: scanned)
    }

    private func commit(
        _ databaseService: DatabaseService,
        _ account: ReefrWallet.Account,
        _ source: NFTSourceId,
        _ events: [NFTTransferEvent],
        from: UInt64,
        scanned: UInt64
    ) async throws {
        try await databaseService.commitNFTLedger(
            account: account,
            source: source,
            scan: ledger(source, events, from: from, scanned: scanned),
            startedAt: .now
        )
    }

    private func aptos(_ id: String, name: String? = nil, metadataURI: String? = nil) -> OwnedNFT {
        OwnedNFT(
            metadataURI: metadataURI,
            name: name,
            reference: NFTReference(collection: "c", isTransferable: true, standard: .aptosTokenV2, tokenId: id)
        )
    }

    private func list(
        _ databaseService: DatabaseService,
        _ account: ReefrWallet.Account,
        _ holdings: [OwnedNFT]
    ) async throws {
        try await databaseService.commitNFTListing(
            account: account,
            source: .walletKit,
            holdings: holdings,
            position: nil,
            startedAt: .now
        )
    }

    private func ids(_ databaseService: DatabaseService, _ account: ReefrWallet.Account) async throws -> [String] {
        try await databaseService.fetchNFTs(account: account).map(\.reference.tokenId).sorted()
    }

    // MARK: Listing

    @Test func completeListingReplacesRowsAndKeepsMetadata() async throws {
        let databaseService = try makeDatabaseService()
        let account = try await makeStakingAccount(databaseService, blockchain: .aptos(.mainnet), address: "0x1")
        try await list(databaseService, account, [aptos("0xa", name: "A"), aptos("0xb")])
        try await list(databaseService, account, [aptos("0xa")])

        let rows = try await databaseService.fetchNFTs(account: account)
        #expect(rows.map(\.reference.tokenId) == ["0xa"])
        #expect(rows.first?.name == "A")
    }

    @Test func metadataFailureKeepsTheRow() async throws {
        let databaseService = try makeDatabaseService()
        let account = try await makeStakingAccount(databaseService, blockchain: .aptos(.mainnet), address: "0x1")
        try await list(databaseService, account, [aptos("0xa", metadataURI: "https://x")])
        let key = try #require(try await databaseService.fetchNFTs(account: account).first?.id)
        try await databaseService.applyNFTMetadata(key: key, name: nil, imageURL: nil, failedAt: .now)

        #expect(try await ids(databaseService, account) == ["0xa"])
        #expect(try await databaseService.fetchNFTMetadataRequests(account: account, retryAfter: .distantPast).isEmpty)
        let due = try await databaseService.fetchNFTMetadataRequests(account: account, retryAfter: .distantFuture)
        #expect(due.count == 1)
    }

    // MARK: Ledger

    @Test func rescannedOverlapDoesNotDoubleCountAndReorgedEventsDisappear() async throws {
        let databaseService = try makeDatabaseService()
        let account = try await evmAccount(databaseService)
        let mint = event(.etherscan, from: Self.zero, to: Self.owner, block: 100, hash: "0xmint")
        let reorged = event(.etherscan, from: Self.owner, to: Self.other, block: 140, hash: "0xgone")

        try await commit(databaseService, account, .etherscan, [mint, reorged], from: 0, scanned: 140)
        #expect(try await ids(databaseService, account).isEmpty)

        // The overlap (108…) is rescanned and the send at 140 was reorged out.
        try await commit(databaseService, account, .etherscan, [], from: 108, scanned: 150)
        #expect(try await ids(databaseService, account) == ["1"])

        // The same mint reported again inside a later window is one event.
        try await commit(databaseService, account, .etherscan, [mint], from: 90, scanned: 150)
        #expect(try await ids(databaseService, account) == ["1"])
        #expect(try await databaseService.fetchNFTScanStates(account: account)[.etherscan]?.scannedBlock == 150)
    }

    @Test func fallbackSourceScansFromGenesisAndKeepsAnOldNFT() async throws {
        let databaseService = try makeDatabaseService()
        let account = try await evmAccount(databaseService)
        let oldMint = { (source: NFTSourceId) in
            self.event(source, from: Self.zero, to: Self.owner, id: "9", block: 10, hash: "0xold")
        }

        try await commit(databaseService, account, .blockscout, [oldMint(.blockscout)], from: 0, scanned: 5000)

        let states = try await databaseService.fetchNFTScanStates(account: account)
        #expect(states[.blockscout]?.scannedBlock == 5000)
        #expect(states[.etherscan] == nil)

        // Blockscout fails; Etherscan has no cursor, so its request starts at block 0.
        let request = NFTScanRequest(minContextSlot: nil, scannedBlock: states[.etherscan]?.scannedBlock)
        #expect(request.overlapStart == 0)

        try await databaseService.commitNFTLedger(
            account: account,
            source: .etherscan,
            scan: ledger(.etherscan, [oldMint(.etherscan)], from: request.overlapStart, scanned: 5001),
            startedAt: .now
        )

        let switched = try await databaseService.fetchNFTScanStates(account: account)
        #expect(try await ids(databaseService, account) == ["9"])
        #expect(switched[.etherscan]?.isSnapshotSource == true)
        #expect(switched[.blockscout]?.isSnapshotSource == false)
        #expect(switched[.blockscout]?.scannedBlock == 5000)
    }

    // MARK: Pending sends

    @Test func confirmedSendStaysSubtractedUntilTheLedgerHasIt() async throws {
        let databaseService = try makeDatabaseService()
        let account = try await evmAccount(databaseService)
        let mint = event(.etherscan, from: Self.zero, to: Self.owner, block: 100, hash: "0xmint")

        try await commit(databaseService, account, .etherscan, [mint], from: 0, scanned: 100)
        let nft = try #require(try await databaseService.fetchNFTs(account: account).first)

        try await databaseService.insertNFTPendingSend(account: account, send: NFTPendingSend(
            broadcastAt: .now, confirmedAt: nil, confirmedPosition: nil, consumedOutpoints: [], expiry: nil,
            expirySlot: nil, nftKey: nft.id, nonce: 0, objectVersion: nil, quantity: 1, quantityBefore: 1,
            state: .broadcast, txHash: "0xsend"
        ))
        #expect(try await databaseService.fetchNFTs(account: account).first?.sendState == .unconfirmed)

        try await databaseService.confirmNFTPendingSend(txHash: "0xsend", position: 120, at: .now)
        #expect(try await ids(databaseService, account).isEmpty)

        // A lagging source still reports the old holding: it stays subtracted.
        try await commit(databaseService, account, .etherscan, [], from: 68, scanned: 110)
        #expect(try await ids(databaseService, account).isEmpty)
        #expect(try await databaseService.fetchNFTPendingSends(account: account).count == 1)

        // Indexed with a receive-back after it: the snapshot is authoritative again.
        let sent = event(.etherscan, from: Self.owner, to: Self.other, block: 120, hash: "0xsend")
        let back = event(.etherscan, from: Self.other, to: Self.owner, block: 130, hash: "0xback")
        try await commit(databaseService, account, .etherscan, [sent, back], from: 78, scanned: 130)

        #expect(try await ids(databaseService, account) == ["1"])
        #expect(try await databaseService.fetchNFTPendingSends(account: account).isEmpty)
    }

    @Test func forgottenOrFailedSendIsRemoved() async throws {
        let databaseService = try makeDatabaseService()
        let account = try await evmAccount(databaseService)

        try await databaseService.insertNFTPendingSend(account: account, send: NFTPendingSend(
            broadcastAt: .now, confirmedAt: nil, confirmedPosition: nil, consumedOutpoints: [], expiry: nil,
            expirySlot: nil, nftKey: "k", nonce: nil, objectVersion: nil, quantity: 1, quantityBefore: 1,
            state: .broadcast, txHash: "0xsend"
        ))
        try await databaseService.deleteNFTPendingSend(txHash: "0xsend")

        #expect(try await databaseService.fetchNFTPendingSends(account: account).isEmpty)
    }
}
