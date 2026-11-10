//
//  ReceiveAddressRow.swift
//  Reefr Wallet
//
//  Created by Andrey Yurkevich on 07.11.26.
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import BigInt
import SwiftUI

#if os(iOS)
struct ReceiveAddressRow: View {
    let address: ReceiveAddress

    var body: some View {
        Menu {
            Button {
                UIPasteboard.general.string = address.address
            } label: {
                Label(.accountDetailsCopyAddress, systemImage: "square.on.square")
            }
        } label: {
            HStack(spacing: 12) {
                Text(verbatim: "\(address.index)")
                    .style(isPhone ? .headline : .medium, foreground: .secondary)
                    .frame(minWidth: isPhone ? 20 : 16, alignment: .trailing)

                Text(verbatim: address.address.shortened(prefix: 11, suffix: 7))
                    .lineLimit(1)
                    .style(.phoneMono, foreground: .primary)

                Spacer(minLength: 8)

                ReceiveAddressAmount(address: address)
                    .fixedSize()
            }
            .padding(.vertical, isPhone ? 6 : 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("receive-address-row-\(address.index)")
    }
}
#endif

/// A receive address's ADA balance, `Unused`, or a dash until a refresh has checked it.
struct ReceiveAddressAmount: View {
    /// The ADA decimals; the amount is stored in lovelace.
    private static let lovelacePerAda = Decimal(1_000_000)

    let address: ReceiveAddress

    var body: some View {
        if let lovelace = address.lovelace, address.isUsed != nil {
            if address.isUsed == true || lovelace > 0 {
                Text(verbatim: formattedAda(lovelace))
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
}
