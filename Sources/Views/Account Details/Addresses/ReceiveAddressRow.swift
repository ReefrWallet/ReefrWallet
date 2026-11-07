//
//  ReceiveAddressRow.swift
//  Reefr Wallet
//
//  Created by Andrey Yurkevich on 07.11.26.
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import BigInt
import SwiftUI

struct ReceiveAddressRow: View {
    /// The ADA decimals; the amount is stored in lovelace.
    private static let lovelacePerAda = Decimal(1_000_000)

    let address: ReceiveAddress

    @State private var isHovering = false
    @State private var isCopied = false

    var body: some View {
        #if os(iOS)
        Menu {
            Button {
                copy()
            } label: {
                Label(.accountDetailsCopyAddress, systemImage: "square.on.square")
            }
        } label: {
            content
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("receive-address-row-\(address.index)")
        #else
        content
            .onHover { isHovering = $0 }
            .accessibilityIdentifier("receive-address-row-\(address.index)")
        #endif
    }

    private var content: some View {
        HStack(spacing: 12) {
            Text(verbatim: "\(address.index)")
                .style(isPhone ? .headline : .medium, foreground: .secondary)
                .frame(minWidth: isPhone ? 20 : 16, alignment: .trailing)

            #if os(iOS)
            Text(address.address.shortened(prefix: 11, suffix: 7))
                .lineLimit(1)
                .style(.phoneMono, foreground: .primary)
            #else
            Text(address.address)
                .lineLimit(1)
                .truncationMode(.middle)
                .style(.mono, foreground: .primary)
            #endif

            #if os(macOS)
            Button {
                copy()
            } label: {
                Image(systemName: isCopied ? "checkmark" : "square.on.square")
            }
            .buttonStyle(.borderless)
            .opacity(isHovering ? 1 : 0)
            .accessibilityLabel(Text(.accountDetailsCopyAddress))
            .accessibilityIdentifier("receive-address-copy-\(address.index)")
            #endif

            Spacer(minLength: 8)

            amount
                .fixedSize()
        }
        .padding(.vertical, isPhone ? 6 : 4)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var amount: some View {
        if let lovelace = address.lovelace, address.isUsed != nil {
            if address.isUsed == true || lovelace > 0 {
                Text(formattedAda(lovelace))
                    .style(isPhone ? .large : .medium, foreground: .primary)
            } else {
                Text(.addressesUnused)
                    .style(isPhone ? .large : .medium, foreground: .secondary)
            }
        } else {
            Text(verbatim: "—")
                .style(isPhone ? .large : .medium, foreground: .secondary)
        }
    }

    private func formattedAda(_ lovelace: BigUInt) -> String {
        Decimal(string: lovelace.description).map { ($0 / Self.lovelacePerAda).formatted(symbol: "ADA") } ?? ""
    }

    private func copy() {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(address.address, forType: .string)
        #else
        UIPasteboard.general.string = address.address
        #endif

        isCopied = true

        Task {
            try? await Task.sleep(for: .seconds(1.5))
            isCopied = false
        }
    }
}
