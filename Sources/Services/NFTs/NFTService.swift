//
//  NFTService.swift
//  Reefr Wallet
//
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import BigInt
import Foundation
import WalletKit

/// Scans accounts' NFTs into the store and tracks NFT sends. See ADR-072.
actor NFTService {
    private let clientProvider: BlockchainClientProvider
    private let confirmation: TransactionConfirmationService
    private let databaseService: DatabaseService
    private let ledgerSources: [any NFTSource]
    private let listingSource: any NFTSource
    private let nodeSource: any NFTSource
    private let metadataResolver: NFTMetadataResolver
    private let queue = ApprovalRefreshQueue(label: "NFTs")

    init(
        clientProvider: BlockchainClientProvider = BlockchainClientProvider(),
        confirmation: TransactionConfirmationService = TransactionConfirmationService(),
        databaseService: DatabaseService? = nil,
        ledgerSources: [any NFTSource] = [BlockscoutNFTSource(), EtherscanNFTSource()],
        listingSource: any NFTSource = WalletKitNFTSource(),
        metadataResolver: NFTMetadataResolver = NFTMetadataResolver(),
        nodeSource: any NFTSource = NodeLogNFTSource()
    ) {
        self.nodeSource = nodeSource
        self.clientProvider = clientProvider
        self.confirmation = confirmation
        self.databaseService = databaseService ?? DI.injectOrFail(DatabaseService.self)
        self.ledgerSources = ledgerSources
        self.listingSource = listingSource
        self.metadataResolver = metadataResolver
    }

    // MARK: - Coverage

    /// Ownership sources for `account`, in precedence order. An EVM account
    /// with an RPC override reads its own node first.
    nonisolated func sources(for account: Account) -> [any NFTSource] {
        let blockchain = account.blockchain

        guard blockchain.supportsNFTs else {
            return []
        }

        if case .evm = blockchain {
            let indexers = ledgerSources.filter { $0.supports(blockchain) }
            return account.rpcURLOverride == nil ? indexers : [nodeSource] + indexers
        }

        return listingSource.supports(blockchain) ? [listingSource] : []
    }

    nonisolated func isCovered(_ account: Account) -> Bool {
        !sources(for: account).isEmpty
    }

    // MARK: - Refresh

    /// Refreshes `account` in the background; calls during a run coalesce.
    nonisolated func enqueueRefresh(_ account: Account) {
        guard isCovered(account) else {
            return
        }

        queue.enqueue(account) { [self] account in
            try await refresh(account)
        }
    }

    /// Resolves unconfirmed sends, scans with the first source that completes,
    /// commits the snapshot and resolves missing metadata.
    func refresh(_ account: Account) async throws {
        try await RequestLane.$current.withValue(.nfts) {
            try await resolveBroadcasts(account)

            let pending = try await databaseService.fetchNFTPendingSends(account: account)
            let states = try await databaseService.fetchNFTScanStates(account: account)
            let cardanoTip = try await cardanoTipBeforeScan(account: account, pending: pending)
            var lastError: (any Error)?

            for source in sources(for: account) {
                let startedAt = Date.now
                let request = NFTScanRequest(
                    minContextSlot: minContextSlot(pending),
                    scannedBlock: states[source.id]?.scannedBlock
                )

                do {
                    let result = try await source.scan(account: account, request: request)
                    try await commit(
                        result,
                        account: account,
                        source: source.id,
                        pending: pending,
                        cardanoTip: cardanoTip,
                        startedAt: startedAt
                    )

                    await resolveMetadata(account)
                    return
                } catch {
                    printError("\(account.name) NFTs from \(source.id.rawValue): \(error)")
                    lastError = error
                }
            }

            throw lastError ?? NFTSourceError.noSource
        }
    }

    private func commit(
        _ result: NFTScanResult,
        account: Account,
        source: NFTSourceId,
        pending: [NFTPendingSend],
        cardanoTip: UInt64?,
        startedAt: Date
    ) async throws {
        switch result {
        case let .ledger(scan):
            try await databaseService.commitNFTLedger(
                account: account,
                source: source,
                scan: scan,
                startedAt: startedAt
            )

        case let .listing(holdings, position):
            try await dropUnlandedAfterListing(
                account: account,
                holdings: holdings,
                position: position,
                pending: pending,
                cardanoTip: cardanoTip
            )

            try await databaseService.commitNFTListing(
                account: account,
                source: source,
                holdings: holdings,
                position: position,
                startedAt: startedAt
            )
        }
    }

    /// Solana listings must be read at or after every confirmed send's slot and
    /// every observed expiry slot.
    private func minContextSlot(_ pending: [NFTPendingSend]) -> UInt64? {
        pending.compactMap { $0.state == .confirmed ? $0.confirmedPosition : $0.expirySlot }.max()
    }

    // MARK: - Sending

    /// Records a broadcast send before its outcome is known.
    func recordBroadcast(_ send: NFTPendingSend, account: Account) async throws {
        try await databaseService.insertNFTPendingSend(account: account, send: send)
    }

    /// Waits for a broadcast send. On success, takes it off the holding (a
    /// self-send records nothing) and refreshes; on failure, forgets it. A
    /// timeout leaves it unresolved and rethrows.
    func confirm(txHash: String, isSelfSend: Bool, account: Account) async throws {
        do {
            let position = try await confirmation.waitForSuccess(hash: txHash, account: account)

            if isSelfSend {
                try await databaseService.deleteNFTPendingSend(txHash: txHash)
            } else {
                try await databaseService.confirmNFTPendingSend(txHash: txHash, position: position, at: .now)
            }

            enqueueRefresh(account)
        } catch TransactionConfirmationError.failed {
            try await databaseService.deleteNFTPendingSend(txHash: txHash)
            throw TransactionConfirmationError.failed(txHash)
        }
    }

    /// Forgets an unconfirmed send at the user's request.
    func forget(txHash: String) async throws {
        try await databaseService.deleteNFTPendingSend(txHash: txHash)
    }

    // MARK: - Unresolved broadcasts

    /// Settles each `.broadcast` send whose outcome is now known, or that has
    /// positive evidence it can't land. See ADR-072.
    private func resolveBroadcasts(_ account: Account) async throws {
        let pending = try await databaseService.fetchNFTPendingSends(account: account).filter { $0.state == .broadcast }

        for send in pending {
            do {
                switch try await confirmation.status(hash: send.txHash, account: account) {
                case let .success(position):
                    try await databaseService.confirmNFTPendingSend(txHash: send.txHash, position: position, at: .now)
                case .failed:
                    try await databaseService.deleteNFTPendingSend(txHash: send.txHash)
                case .notFound, .pending:
                    if try await isReplaced(send, account: account) {
                        printDebug("NFT send \(send.txHash) can't land; dropping")
                        try await databaseService.deleteNFTPendingSend(txHash: send.txHash)
                    } else {
                        try await observeSolanaExpiry(send, account: account)
                    }
                }
            } catch {
                printError("NFT send \(send.txHash) status: \(error)")
            }
        }
    }

    /// Evidence (1): another transaction consumed the send's nonce or inputs.
    private func isReplaced(_ send: NFTPendingSend, account: Account) async throws -> Bool {
        let client = try clientProvider.makeClient(blockchain: account.blockchain, rpcURL: account.rpcURLOverride)

        switch client {
        case let client as EthereumRPCClient:
            return try await isNonceReused(send, account: account, client: client)
        case let client as CardanoClient:
            let inputs = send.consumedOutpoints.compactMap(Self.cardanoInput)
            guard !inputs.isEmpty else {
                return false
            }

            return try await client.isSpentByOtherTransaction(hash: send.txHash, inputs: inputs)
        case let client as SuiGRPCClient:
            guard let reference = send.consumedOutpoints.first.flatMap(Self.suiReference) else {
                return false
            }

            let consumer = try await client.consumingTransaction(of: reference)
            return consumer.map { $0 != send.txHash } ?? false
        default:
            return false
        }
    }

    /// The account's nonce has moved past the send's, and a synced outgoing
    /// transaction with a different hash holds that nonce.
    private func isNonceReused(
        _ send: NFTPendingSend,
        account: Account,
        client: EthereumRPCClient
    ) async throws -> Bool {
        guard let nonce = send.nonce, let accountId = account.id else {
            return false
        }

        let countParams = try JSONValue.array([.string(account.address), .string("latest")]).encoded()
        let countValue = try JSONValue(
            data: await client.request(method: "eth_getTransactionCount", params: countParams)
        )

        guard let count = countValue.stringValue.flatMap({ UInt64($0.dropFirst(2), radix: 16) }), count > nonce else {
            return false
        }

        let candidates = try await databaseService.fetchTransactions(accountId: accountId).filter {
            $0.identifier.lowercased() != send.txHash.lowercased()
                && $0.sender?.lowercased() == account.address.lowercased()
                && ($0.timestamp ?? .distantFuture) >= send.broadcastAt.addingTimeInterval(-600)
        }

        for candidate in candidates {
            let params = try JSONValue.array([.string(candidate.identifier)]).encoded()
            let transaction = try JSONValue(
                data: await client.request(method: "eth_getTransactionByHash", params: params)
            )

            let candidateNonce = transaction["nonce"]?.stringValue.flatMap { UInt64($0.dropFirst(2), radix: 16) }

            if candidateNonce == nonce, transaction["blockNumber"]?.stringValue != nil {
                return true
            }
        }

        return false
    }

    /// Records the first slot read after a Solana send's blockhash expired.
    private func observeSolanaExpiry(_ send: NFTPendingSend, account: Account) async throws {
        guard send.expirySlot == nil, let expiry = send.expiry,
              let client = try clientProvider.makeClient(blockchain: account.blockchain, rpcURL: account.rpcURLOverride)
                as? SolanaRPCClient
        else {
            return
        }

        let (height, slot) = try await client.blockHeightAndSlot()

        if height > expiry {
            try await databaseService.setNFTPendingSendExpirySlot(txHash: send.txHash, slot: slot)
        }
    }

    private func cardanoTipBeforeScan(account: Account, pending: [NFTPendingSend]) async throws -> UInt64? {
        guard case .cardano = account.blockchain, pending.contains(where: { $0.state == .broadcast }),
              let client = try clientProvider.makeClient(blockchain: account.blockchain, rpcURL: account.rpcURLOverride)
                as? CardanoClient
        else {
            return nil
        }

        return try? await client.tipSlot()
    }

    /// Evidence (2): a listing ordered after a broadcast send's expiry still
    /// shows the asset as it was before the send.
    private func dropUnlandedAfterListing(
        account: Account,
        holdings: [OwnedNFT],
        position: NFTSnapshotPosition?,
        pending: [NFTPendingSend],
        cardanoTip: UInt64?
    ) async throws {
        let accountKey = try await databaseService.nftAccountKey(account: account)
        let keyed = holdings.map { (NFTKey.make(accountKey: accountKey, reference: $0.reference), $0) }
        let held = Dictionary(keyed) { first, _ in first }

        for send in pending where send.state == .broadcast {
            guard let holding = held[send.nftKey], holding.quantity >= send.quantityBefore,
                  Self.isPastExpiry(send, position: position, cardanoTip: cardanoTip)
            else {
                continue
            }

            printDebug("NFT send \(send.txHash) expired unlanded; dropping")
            try await databaseService.deleteNFTPendingSend(txHash: send.txHash)
        }
    }

    static func isPastExpiry(_ send: NFTPendingSend, position: NFTSnapshotPosition?, cardanoTip: UInt64?) -> Bool {
        guard let expiry = send.expiry else {
            return false
        }

        switch position {
        case let .aptos(_, timestamp):
            return timestamp.map { UInt64($0.timeIntervalSince1970) > expiry } ?? false
        case let .cardano(outpoints):
            return (cardanoTip ?? 0) > expiry && Set(send.consumedOutpoints).isSubset(of: outpoints)
        case let .solana(slot):
            return send.expirySlot.map { slot >= $0 } ?? false
        case .sui, nil:
            return false
        }
    }

    // MARK: - Metadata

    private func resolveMetadata(_ account: Account) async {
        if case .evm = account.blockchain {
            await readEVMMetadataURIs(account)
        }

        let retryAfter = Date.now.addingTimeInterval(-NFTMetadataResolver.retryInterval)

        guard let requests = try? await databaseService.fetchNFTMetadataRequests(
            account: account,
            retryAfter: retryAfter
        ) else {
            return
        }

        for request in requests.prefix(200) {
            do {
                let metadata = try await metadataResolver.resolve(request.metadataURI)
                try await databaseService.applyNFTMetadata(
                    key: request.key,
                    name: metadata.name,
                    imageURL: metadata.image,
                    failedAt: nil
                )
            } catch {
                try? await databaseService.applyNFTMetadata(key: request.key, name: nil, imageURL: nil, failedAt: .now)
            }
        }
    }

    private func readEVMMetadataURIs(_ account: Account) async {
        guard let rows = try? await databaseService.fetchNFTsWithoutMetadataURI(account: account), !rows.isEmpty,
              let client = try? clientProvider.ethereumClient(for: account),
              let uris = try? await client.nftMetadataURIs(rows.map(\.reference))
        else {
            return
        }

        let updates = zip(rows, uris).compactMap { row, uri in uri.map { (row.key, $0) } }
        try? await databaseService.applyNFTMetadataURIs(Dictionary(updates) { first, _ in first })
    }

    // MARK: - Parsing

    static func cardanoInput(_ outpoint: String) -> CardanoSpentInput? {
        let parts = outpoint.split(separator: "#")
        guard parts.count == 2, let index = UInt32(parts[1]) else {
            return nil
        }

        return CardanoSpentInput(outputIndex: index, txHash: String(parts[0]))
    }

    static func suiReference(_ string: String) -> SuiObjectReference? {
        let parts = string.split(separator: "|").map(String.init)
        guard parts.count == 3, let version = UInt64(parts[1]),
              let id = try? Data(hexString: parts[0]),
              let digest = try? Base58.decode(parts[2])
        else {
            return nil
        }

        return SuiObjectReference(objectId: id, version: version, digest: digest)
    }
}
