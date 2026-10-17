//
//  DappIconView.swift
//  Reefr Wallet
//
//  Created by Andrey Yurkevich on 17.10.26.
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import SwiftUI

/// A dapp's remote icon, falling back to a globe.
struct DappIconView: View {
    let url: URL?
    var size: CGFloat = 20

    var body: some View {
        AsyncImage(url: url) { image in
            image.resizable().scaledToFit()
        } placeholder: {
            Image(systemName: "globe")
                .resizable()
                .scaledToFit()
                .style(foreground: .secondary)
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size / 5))
    }
}
