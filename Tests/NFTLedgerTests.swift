// Pure NFT logic: ledger replay, pending-send reconciliation, metadata URIs,
// Blockscout/Etherscan parsing and send gating (ADR-072).

import BigInt
import Foundation
import Testing
import WalletKit
@testable import ReefrWallet

private let owner = "0x" + String(repeating: "aa", count: 20)
private let other = "0x" + String(repeating: "bb", count: 20)
private let contract = "0x" + String(repeating: "cc", count: 20)
private let zero = "0x" + String(repeating: "00", count: 20)

private func event(
    _ standard: NFTStandard = .erc721,
    from: String,
    to: String,
    id: String = "1",
    amount: BigUInt = 1,
    block: UInt64,
    log: Int = 0,
    position: Int = 0,
    hash: String? = nil
) -> NFTTransferEvent {
    NFTTransferEvent(
        amount: amount,
        batchPosition: position,
        blockHash: nil,
        blockNumber: block,
        contract: contract,
        from: from,
        logIndex: log,
        source: NFTSourceId.etherscan.rawValue,
        standard: standard,
        to: to,
        tokenId: id,
        transactionIndex: 0,
        txHash: hash ?? "0x\(block)\(log)\(position)"
    )
}

private func reference(_ standard: NFTStandard = .erc721, id: String = "1") -> NFTReference {
    NFTReference(collection: contract, isTransferable: true, standard: standard, tokenId: id)
}

private func pending(
    _ key: String,
    hash: String = "0xsend",
    quantity: BigUInt = 1,
    before: BigUInt = 1,
    state: NFTPendingSend.State = .confirmed,
    position: UInt64? = nil,
    outpoints: [String] = [],
    objectVersion: UInt64? = nil,
    confirmedAt: Date? = .now
) -> NFTPendingSend {
    NFTPendingSend(
        broadcastAt: .now,
        confirmedAt: state == .confirmed ? confirmedAt : nil,
        confirmedPosition: position,
        consumedOutpoints: outpoints,
        expiry: nil,
        expirySlot: nil,
        nftKey: key,
        nonce: nil,
        objectVersion: objectVersion,
        quantity: quantity,
        quantityBefore: before,
        state: state,
        txHash: hash
    )
}

private let accountKey = "x-coredata://store/AccountModel/p1"

private func key(_ reference: NFTReference) -> String {
    NFTKey.make(accountKey: accountKey, reference: reference)
}

// MARK: - Ledger

struct NFTLedgerTests {
    @Test func erc721BelongsToTheLatestRecipient() {
        let events = [
            event(from: zero, to: owner, block: 1),
            event(from: owner, to: other, block: 2),
            event(from: other, to: owner, block: 3)
        ]

        #expect(NFTLedger.holdings(events: events, owner: owner) == [reference(): 1])
        #expect(NFTLedger.holdings(events: Array(events.prefix(2)), owner: owner).isEmpty)
    }

    @Test func sameTransactionOrderUsesLogIndex() {
        // A→B then B→A in one transaction: the later log wins.
        let events = [
            event(from: other, to: owner, block: 5, log: 2, hash: "0xt"),
            event(from: owner, to: other, block: 5, log: 1, hash: "0xt")
        ]

        #expect(NFTLedger.holdings(events: events, owner: owner) == [reference(): 1])
    }

    @Test func erc1155IsIncomingMinusOutgoingAndDropsAtZero() {
        let events = [
            event(.erc1155, from: zero, to: owner, amount: 5, block: 1),
            event(.erc1155, from: owner, to: other, amount: 2, block: 2)
        ]

        #expect(NFTLedger.holdings(events: events, owner: owner) == [reference(.erc1155): 3])

        let spent = events + [event(.erc1155, from: owner, to: other, amount: 3, block: 3)]
        #expect(NFTLedger.holdings(events: spent, owner: owner).isEmpty)
    }

    @Test func ownerComparisonIgnoresCase() {
        let events = [event(from: zero, to: owner.uppercased().replacingOccurrences(of: "0X", with: "0x"), block: 1)]
        #expect(NFTLedger.holdings(events: events, owner: owner) == [reference(): 1])
    }

    @Test func transferBatchKeysDifferByPosition() {
        let first = event(.erc1155, from: zero, to: owner, id: "1", block: 1, log: 3, position: 0, hash: "0xb")
        let second = event(.erc1155, from: zero, to: owner, id: "2", block: 1, log: 3, position: 1, hash: "0xb")

        #expect(first.key(accountKey: accountKey) != second.key(accountKey: accountKey))
    }

    @Test func nftKeyIncludesTheStandard() {
        #expect(key(reference(.erc721)) != key(reference(.erc1155)))
    }
}

// MARK: - Reconciler

struct NFTReconcilerTests {
    private func held(_ reference: NFTReference, quantity: BigUInt = 1, version: UInt64? = nil) -> OwnedNFT {
        OwnedNFT(quantity: quantity, reference: reference, version: version)
    }

    @Test func ledgerWithoutTheSendKeepsSubtracting() {
        let nft = reference()
        let result = NFTReconciler.apply(
            holdings: [held(nft)],
            evidence: .ledger(transferKeys: []),
            pending: [pending(key(nft))],
            nftKey: key
        )

        #expect(result.holdings.isEmpty)
        #expect(result.reflected.isEmpty)
    }

    @Test func ledgerWithTheSendIsAuthoritativeIncludingAReceiveBack() {
        let nft = reference()
        let keys = NFTLedger.transferKeys([event(from: owner, to: other, block: 9, hash: "0xsend")])
        let result = NFTReconciler.apply(
            holdings: [held(nft)],
            evidence: .ledger(transferKeys: keys),
            pending: [pending(key(nft))],
            nftKey: key
        )

        #expect(result.holdings.count == 1)
        #expect(result.reflected == ["0xsend"])
    }

    @Test func partialErc1155SendSubtractsItsQuantity() {
        let nft = reference(.erc1155)
        let result = NFTReconciler.apply(
            holdings: [held(nft, quantity: 5)],
            evidence: .listing(nil),
            pending: [pending(key(nft), quantity: 2, before: 5)],
            nftKey: key
        )

        #expect(result.holdings.first?.quantity == 3)
    }

    @Test func broadcastSendsDoNotChangeHoldings() {
        let nft = reference()
        let result = NFTReconciler.apply(
            holdings: [held(nft)],
            evidence: .listing(nil),
            pending: [pending(key(nft), state: .broadcast)],
            nftKey: key
        )

        #expect(result.holdings.count == 1)
        #expect(result.reflected.isEmpty)
    }

    @Test(arguments: [
        (NFTSnapshotPosition.aptos(processorVersion: 99, processorTimestamp: nil), false),
        (.aptos(processorVersion: 100, processorTimestamp: nil), true),
        (.solana(slot: 99), false),
        (.solana(slot: 100), true)
    ])
    func positionedListingsReflectAtOrPastTheSend(position: NFTSnapshotPosition, reflected: Bool) {
        let send = pending("k", position: 100)
        #expect(NFTReconciler.isReflected(send, holding: nil, evidence: .listing(position)) == reflected)
    }

    @Test func cardanoReflectsOnceConsumedOutpointsAreGone() {
        let send = pending("k", outpoints: ["aa#0"])

        let stale = NFTReconciler.Evidence.listing(.cardano(outpoints: ["aa#0", "bb#1"]))
        let current = NFTReconciler.Evidence.listing(.cardano(outpoints: ["bb#1"]))

        #expect(!NFTReconciler.isReflected(send, holding: nil, evidence: stale))
        #expect(NFTReconciler.isReflected(send, holding: nil, evidence: current))
    }

    @Test func suiReflectsWhenAbsentOrAtANewerVersion() {
        let nft = NFTReference(collection: "0xa::m::T", isTransferable: true, standard: .suiObject, tokenId: "0x1")
        let send = pending(key(nft), objectVersion: 10)
        let evidence = NFTReconciler.Evidence.listing(.sui(checkpoint: nil, epoch: nil))

        #expect(NFTReconciler.isReflected(send, holding: nil, evidence: evidence))
        #expect(!NFTReconciler.isReflected(send, holding: held(nft, version: 10), evidence: evidence))
        #expect(NFTReconciler.isReflected(send, holding: held(nft, version: 12), evidence: evidence))
    }

    @Test func sendStateIsUnconfirmedThenWaitingAfterAnHour() {
        let now = Date.now
        let broadcast = [pending("k", state: .broadcast)]
        let stale = [pending("k", confirmedAt: now.addingTimeInterval(-3601))]
        let fresh = [pending("k", confirmedAt: now.addingTimeInterval(-60))]

        #expect(NFTReconciler.sendState(for: "k", pending: broadcast, source: .blockscout, now: now) == .unconfirmed)
        #expect(NFTReconciler.sendState(for: "k", pending: stale, source: .blockscout, now: now)
            == .waitingForIndex(source: "Blockscout"))
        #expect(NFTReconciler.sendState(for: "k", pending: fresh, source: .blockscout, now: now) == nil)
    }
}

// MARK: - Expiry evidence

struct NFTExpiryEvidenceTests {
    private func send(expiry: UInt64?, expirySlot: UInt64? = nil, outpoints: [String] = []) -> NFTPendingSend {
        var send = pending("k", state: .broadcast, outpoints: outpoints)
        send.expiry = expiry
        send.expirySlot = expirySlot
        return send
    }

    @Test func expiryAloneIsNotEvidence() {
        #expect(!NFTService.isPastExpiry(send(expiry: 1), position: nil, cardanoTip: nil))
        #expect(!NFTService.isPastExpiry(send(expiry: nil), position: .solana(slot: .max), cardanoTip: nil))
    }

    @Test func solanaNeedsAReadAtOrAfterTheExpirySlot() {
        let expired = send(expiry: 50, expirySlot: 900)

        #expect(!NFTService.isPastExpiry(expired, position: .solana(slot: 899), cardanoTip: nil))
        #expect(NFTService.isPastExpiry(expired, position: .solana(slot: 900), cardanoTip: nil))
        #expect(!NFTService.isPastExpiry(send(expiry: 50), position: .solana(slot: 900), cardanoTip: nil))
    }

    @Test func aptosNeedsTheProcessorPastExpiry() {
        let late = NFTSnapshotPosition.aptos(processorVersion: 1, processorTimestamp: Date(timeIntervalSince1970: 1001))
        let early = NFTSnapshotPosition.aptos(processorVersion: 1, processorTimestamp: Date(timeIntervalSince1970: 999))

        #expect(NFTService.isPastExpiry(send(expiry: 1000), position: late, cardanoTip: nil))
        #expect(!NFTService.isPastExpiry(send(expiry: 1000), position: early, cardanoTip: nil))
    }

    @Test func cardanoNeedsTipPastTTLAndInputsStillUnspent() {
        let send = send(expiry: 100, outpoints: ["aa#0"])

        #expect(NFTService.isPastExpiry(send, position: .cardano(outpoints: ["aa#0"]), cardanoTip: 101))
        #expect(!NFTService.isPastExpiry(send, position: .cardano(outpoints: ["aa#0"]), cardanoTip: 100))
        #expect(!NFTService.isPastExpiry(send, position: .cardano(outpoints: []), cardanoTip: 101))
    }

    @Test func suiHasNoExpiry() {
        #expect(!NFTService.isPastExpiry(send(expiry: 1), position: .sui(checkpoint: 9, epoch: 9), cardanoTip: nil))
    }
}

// MARK: - Metadata

struct NFTMetadataResolverTests {
    @Test func rewritesIpfsAndArweave() {
        #expect(NFTMetadataResolver.displayURL("ipfs://Qm/1.json")?.absoluteString == "https://ipfs.io/ipfs/Qm/1.json")
        #expect(NFTMetadataResolver.displayURL("ipfs://ipfs/Qm")?.absoluteString == "https://ipfs.io/ipfs/Qm")
        #expect(NFTMetadataResolver.displayURL("ar://abc")?.absoluteString == "https://arweave.net/abc")
        #expect(NFTMetadataResolver.displayURL("ftp://x") == nil)
    }

    @Test func resolvesPlainAndBase64DataURIs() async throws {
        let resolver = NFTMetadataResolver()
        let plain = try await resolver.resolve(#"data:application/json,{"name":"Mock NFT","image":"ipfs://img"}"#)
        let base64 = try await resolver.resolve(
            "data:application/json;base64," + Data(#"{"name":"B","image_url":"https://x/i.png"}"#.utf8).base64EncodedString()
        )

        #expect(plain == .init(image: "ipfs://img", name: "Mock NFT"))
        #expect(base64 == .init(image: "https://x/i.png", name: "B"))
    }
}

// MARK: - Sources

struct NFTSourceParsingTests {
    private func blockscoutItems(_ json: String) throws -> [BlockscoutNFTTransfer] {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode([BlockscoutNFTTransfer].self, from: Data(json.utf8))
    }

    @Test func blockscoutSingleAndArrayTotalsBecomeEvents() throws {
        let items = try blockscoutItems("""
            [
              {"block_hash": "0xh", "block_number": 10, "from": {"hash": "\(zero)"}, "to": {"hash": "\(owner)"},
               "log_index": 4, "transaction_hash": "0xt1",
               "token": {"address_hash": "\(contract)", "name": "Coll", "type": "ERC-721"},
               "total": {"token_id": "7", "token_instance": {"image_url": "https://i", "metadata": {"name": "Seven"}}}},
              {"block_hash": "0xh", "block_number": 11, "from": {"hash": "\(owner)"}, "to": {"hash": "\(other)"},
               "log_index": 2, "transaction_hash": "0xt2",
               "token": {"address_hash": "\(contract)", "name": "Coll", "type": "ERC-1155"},
               "total": [{"token_id": "1", "value": "3"}, {"token_id": "2", "value": "4"}]}
            ]
            """)

        let events = BlockscoutNFTSource.events(items).sorted(by: NFTTransferEvent.ledgerOrder)
        #expect(events.map(\.tokenId) == ["7", "1", "2"])
        #expect(events.map(\.batchPosition) == [0, 0, 1])
        #expect(events.map(\.amount) == [1, 3, 4])
        #expect(events.map(\.logIndex) == [4, 2, 2])

        let metadata = BlockscoutNFTSource.metadata(items)[NFTLedger.assetKey(reference(id: "7"))]
        #expect(metadata?.name == "Seven")
        #expect(metadata?.imageURI == "https://i")
        #expect(metadata?.collectionName == "Coll")
    }

    @Test func etherscanReceiptLogsGiveLogIndexAndBatchPositions() throws {
        let template = try JSONDecoder().decode(EtherscanNFTTransfer.self, from: Data("""
            {"blockHash": "0xh", "blockNumber": "20", "contractAddress": "\(contract)", "from": "\(owner)",
             "hash": "0xtx", "to": "\(other)", "tokenID": "1", "transactionIndex": "3"}
            """.utf8))

        func topic(_ address: String) -> JSONValue {
            .string("0x" + String(repeating: "0", count: 24) + address.dropFirst(2))
        }

        func word(_ value: BigUInt) -> Data {
            let bytes = value.serialize()
            return Data(repeating: 0, count: 32 - bytes.count) + bytes
        }

        let transferTopic = "0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef"
        let batchTopic = "0x4a39dc06d4c0dbc64b70af90fd698a233a518aa5d07e595d983b8c0526c8f7fb"
        var batchData = word(64) + word(160)
        batchData += word(2) + word(5) + word(6)
        batchData += word(2) + word(1) + word(2)

        let erc721 = JSONValue.object([
            "address": .string(contract),
            "logIndex": .string("0x7"),
            "topics": .array([
                .string(transferTopic),
                topic(owner),
                topic(other),
                .string("0x" + String(repeating: "0", count: 63) + "1")
            ]),
            "data": .string("0x")
        ])
        let batch = JSONValue.object([
            "address": .string(contract),
            "logIndex": .string("0x8"),
            "topics": .array([.string(batchTopic), topic(owner), topic(owner), topic(other)]),
            "data": .string("0x" + batchData.map { String(format: "%02x", $0) }.joined())
        ])

        let single = EtherscanNFTSource.decode(log: erc721, template: template)
        let items = EtherscanNFTSource.decode(log: batch, template: template)

        #expect(single.map(\.logIndex) == [7])
        #expect(single.first?.standard == .erc721)
        #expect(items.map(\.tokenId) == ["5", "6"])
        #expect(items.map(\.amount) == [1, 2])
        #expect(items.map(\.batchPosition) == [0, 1])
        #expect(items.allSatisfy { $0.logIndex == 8 && $0.transactionIndex == 3 && $0.blockNumber == 20 })
    }
}

// MARK: - Send gating

struct NFTSendGatingTests {
    private func keyStore(_ kind: KeyStore.Kind, entropy: Data? = Data([1])) -> KeyStore {
        KeyStore(deviceId: nil, kind: kind, name: "K", sealedEntropy: entropy, transport: nil, vendor: nil)
    }

    private func nft(transferable: Bool = true, state: NFTSendState? = nil, quantity: BigUInt = 1) -> NFT {
        NFT(
            collectionName: nil,
            id: "k",
            imageURL: nil,
            isTransferable: transferable,
            metadataURI: nil,
            name: nil,
            objectType: nil,
            quantity: quantity,
            reference: reference(),
            sendState: state
        )
    }

    @Test func watchOnlyAndTrezorOnAptosOrSuiCannotSend() {
        #expect(!nft().canSend(keyStore: keyStore(.watchOnly), blockchain: .evm(.ethereum(.mainnet))))
        #expect(!nft().canSend(keyStore: keyStore(.trezor), blockchain: .aptos(.mainnet)))
        #expect(!nft().canSend(keyStore: keyStore(.trezor), blockchain: .sui(.mainnet)))
        #expect(nft().canSend(keyStore: keyStore(.trezor), blockchain: .solana(.mainnet)))
        #expect(nft().canSend(keyStore: keyStore(.local), blockchain: .sui(.mainnet)))
    }

    @Test func localCardanoNeedsEntropy() {
        #expect(!nft().canSend(keyStore: keyStore(.local, entropy: nil), blockchain: .cardano(.mainnet)))
        #expect(nft().canSend(keyStore: keyStore(.local), blockchain: .cardano(.mainnet)))
    }

    @Test func nonTransferableUnconfirmedOrEmptyCannotSend() {
        let local = keyStore(.local)

        #expect(!nft(transferable: false).canSend(keyStore: local, blockchain: .evm(.ethereum(.mainnet))))
        #expect(!nft(state: .unconfirmed).canSend(keyStore: local, blockchain: .evm(.ethereum(.mainnet))))
        let waiting = nft(state: .waitingForIndex(source: "x"))
        #expect(waiting.canSend(keyStore: local, blockchain: .evm(.ethereum(.mainnet))))
        #expect(!nft(quantity: 0).canSend(keyStore: local, blockchain: .evm(.ethereum(.mainnet))))
    }
}
