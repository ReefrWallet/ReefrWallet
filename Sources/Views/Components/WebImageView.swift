//
//  WebImageView.swift
//  Reefr Wallet
//
//  Created by Andrey Yurkevich on 12.12.25.
//  Copyright © 2025 Reefr Wallet. All rights reserved.
//

import SwiftUI

struct WebImageView: View {
    let url: URL?

    var body: some View {
        if let url {
            AsyncImage(url: url) { image in
                image
                    .resizable()
                    .scaledToFit()
            } placeholder: {
                placeholderView
            }
        } else {
            placeholderView
        }
    }
}

private extension WebImageView {
    var placeholderView: some View {
        ZStack(alignment: .center) {
            Color.secondary

            Text("?")
                .style(.largeHeader, foreground: .secondary)
        }
    }
}
