//
//  EmptyStateView.swift
//  Reefr Wallet
//
//  Created by Andrey Yurkevich on 15.10.26.
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import SwiftUI

/// Full-size placeholder: a dimmed brand mark with a caption below it.
struct EmptyStateView: View {
    private static let markOpacity: CGFloat = 0.4
    private static let markSide: CGFloat = 128
    private static let spacing: CGFloat = 16

    let title: LocalizedStringKey

    init(_ title: LocalizedStringKey) {
        self.title = title
    }

    var body: some View {
        VStack(spacing: Self.spacing) {
            Image(.emptyStateMark)
                .resizable()
                .renderingMode(.template)
                .scaledToFit()
                // Shrinks with the container instead of clipping in tight panes.
                .frame(maxWidth: Self.markSide, maxHeight: Self.markSide)
                .style(foreground: .secondary.opacity(Self.markOpacity))
                .accessibilityHidden(true)

            Text(title)
                .style(.medium, foreground: .secondary)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

#Preview {
    EmptyStateView("Zero Balances")
        .frame(width: 800, height: 500)
}
