//
//  AccountNFTsView.swift
//  Reefr Wallet
//
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import SwiftUI
import WalletKit

/// The account's NFTs as a plain text table. Selecting a row enables Send.
struct AccountNFTsView: View {
    @Bindable var model: AccountNFTsModel

    let keyStore: KeyStore
    var searchText = ""
    let onSend: (NFT) -> Void

    @State private var forgetting: NFT?

    var body: some View {
        let nfts = model.visible(matching: searchText)
        let showsCount = model.isCovered && model.isLoaded
        // A hidden placeholder keeps the header's height while the tab loads.
        let countText = String(localized: .nftsNftCount(showsCount ? nfts.count : 0))

        #if os(iOS)
        // The list's rows come and go, so the loads hang off the header row that's always there.
        AccountCountLabel(text: countText)
            .opacity(showsCount ? 1 : 0)
            .accessibilityIdentifier("account-nfts-count")
            .accessibilityHidden(!showsCount)
            .task { await model.observe() }
            .task { await model.refresh() }

        if model.isSui {
            AccountCountLabel(text: String(localized: .nftsSuiCaption))
        }
        #endif

        content(nfts)
            #if os(macOS)
            // Outside the content switch, so the header stays put while the tab loads.
            .statusBar(edge: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: countText)
                        .opacity(showsCount ? 1 : 0)
                        .accessibilityIdentifier("account-nfts-count")
                        .accessibilityHidden(!showsCount)
                        .style(.mediumHeader, foreground: .primary)

                    if model.isSui {
                        Text(.nftsSuiCaption)
                            .style(.callout, foreground: .secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading)
                .padding(.bottom, 8)
            }
            .task { await model.observe() }
            .task { await model.refresh() }
            #endif
            .confirmationDialog(
                Text(.nftsForgetTitle),
                isPresented: Binding(get: { forgetting != nil }, set: { if !$0 { forgetting = nil } }),
                presenting: forgetting
            ) { nft in
                Button(.nftsForget, role: .destructive) {
                    Task { await model.forgetUnconfirmedSend(nft) }
                }
            } message: { _ in
                Text(.nftsForgetMessage)
            }
    }
}

private extension AccountNFTsView {
    @ViewBuilder
    func content(_ nfts: [NFT]) -> some View {
        #if os(iOS)
        if !model.isCovered {
            AccountEmptyRow(title: .nftsNoSource)
        } else if model.isLoaded, nfts.isEmpty {
            AccountEmptyRow(title: .nftsNoNfts)
                .accessibilityIdentifier("account-no-nfts")
        } else {
            ForEach(nfts) { nft in
                row(nft)
            }
        }
        #else
        if !model.isCovered {
            EmptyStateView(.nftsNoSource)
        } else if !model.isLoaded {
            Color.clear
        } else if nfts.isEmpty {
            EmptyStateView(.nftsNoNfts)
                .accessibilityIdentifier("account-no-nfts")
        } else {
            Table(nfts, selection: $model.selection) { columns }
                .contextMenu(forSelectionType: NFT.ID.self) { ids in
                    if let nft = nfts.first(where: { ids.contains($0.id) }) {
                        contextMenu(nft)
                    }
                }
        }
        #endif
    }

    #if os(iOS)
    func row(_ nft: NFT) -> some View {
        let isSelected = model.selection == nft.id

        return Button {
            model.selection = isSelected ? nil : nft.id
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(verbatim: nft.displayName)
                        .style(.headline, foreground: .primary)

                    Spacer()

                    Text(verbatim: nft.quantity.description)
                        .style(.callout, foreground: .secondary)
                        .accessibilityIdentifier("nft-quantity-\(nft.reference.tokenId)")
                }

                Text(verbatim: nft.collectionName ?? nft.reference.collection)
                    .style(.callout, foreground: .secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                if let state = nft.sendState {
                    Text(state.title)
                        .style(.caption, foreground: .orange)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu { contextMenu(nft) }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("nft-row-\(nft.reference.tokenId)")
        .listRowBackground(isSelected ? Color.accentColor.opacity(0.18) : nil)
    }
    #else
    @TableColumnBuilder<NFT, Never>
    var columns: some TableColumnContent<NFT, Never> {
        TableColumn(.nftsName) { nft in
            Text(verbatim: nft.displayName)
                .style(.medium, foreground: .primary)
                .accessibilityIdentifier("nft-row-\(nft.reference.tokenId)")
        }
        .width(min: 120, ideal: 180)

        TableColumn(.nftsCollection) { nft in
            Text(verbatim: nft.collectionName ?? nft.objectType ?? nft.reference.collection)
                .style(.medium, foreground: .secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(nft.objectType ?? nft.reference.collection)
        }
        .width(min: 120, ideal: 200)

        TableColumn(.nftsTokenId) { nft in
            Text(verbatim: nft.reference.tokenId)
                .style(.mono, foreground: .secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(nft.reference.tokenId)
        }
        .width(min: 80, ideal: 140)

        TableColumn(.nftTransferQuantity) { nft in
            Text(verbatim: nft.quantity.description)
                .style(.medium, foreground: .primary)
                .accessibilityIdentifier("nft-quantity-\(nft.reference.tokenId)")
        }
        .width(min: 50, ideal: 70)

        TableColumn(.nftsStatus) { nft in
            if let state = nft.sendState {
                Text(state.title)
                    .style(.medium, foreground: .orange)
            } else if !nft.isTransferable {
                Text(.nftsNotTransferable)
                    .style(.medium, foreground: .secondary)
            }
        }
        .width(min: 80, ideal: 160)
    }
    #endif

    @ViewBuilder
    func contextMenu(_ nft: NFT) -> some View {
        Button {
            onSend(nft)
        } label: {
            Label(.commonSend, systemImage: "paperplane")
        }
        .disabled(!nft.canSend(keyStore: keyStore, blockchain: model.account.blockchain))

        if nft.sendState == .unconfirmed {
            Button(role: .destructive) {
                forgetting = nft
            } label: {
                Label(.nftsForgetUnconfirmedSend, systemImage: "xmark.circle")
            }
        }
    }
}

extension NFTSendState {
    var title: LocalizedStringResource {
        switch self {
        case .unconfirmed: .nftsUnconfirmedSend
        case let .waitingForIndex(source): .nftsWaitingForIndex(source)
        }
    }
}
