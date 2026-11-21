//
//  AccountNFTsModel.swift
//  Reefr Wallet
//
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import Foundation
import SwiftUI

@MainActor
@Observable
final class AccountNFTsModel {
    private(set) var isLoaded = false
    private(set) var isRefreshing = false
    private(set) var nfts: [NFT] = []
    var selection: NFT.ID?

    let account: Account

    private let databaseService = DI.injectOrFail(DatabaseService.self)
    private let nftService = DI.injectOrFail(NFTService.self)

    init(_ account: Account) {
        self.account = account
    }

    var isCovered: Bool {
        nftService.isCovered(account)
    }

    var isSui: Bool {
        if case .sui = account.blockchain {
            return true
        }

        return false
    }

    var selected: NFT? {
        nfts.first { $0.id == selection }
    }

    func visible(matching searchText: String) -> [NFT] {
        nfts.filter { $0.matches(searchText) }
    }

    func observe() async {
        let account = account
        let container = databaseService.modelContainer

        await container.observeSaves(affecting: ["NFTModel", "NFTPendingSendModel"]) {
            nfts = try await container.readSnapshot { reader in
                try await reader.fetchNFTs(account: account)
            }

            isLoaded = true
        }
    }

    func refresh() async {
        guard isCovered, !isRefreshing else {
            return
        }

        isRefreshing = true
        defer { isRefreshing = false }

        do {
            try await nftService.refresh(account)
        } catch {
            printError("\(account.name) NFTs: \(error)")
        }
    }

    func forgetUnconfirmedSend(_ nft: NFT) async {
        do {
            let pending = try await databaseService.fetchNFTPendingSends(account: account)

            for send in pending where send.nftKey == nft.id && send.state == .broadcast {
                try await nftService.forget(txHash: send.txHash)
            }
        } catch {
            printError(error)
        }
    }
}
