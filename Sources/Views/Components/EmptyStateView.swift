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
    private static let markHeight: CGFloat = 128
    private static let markOpacity: CGFloat = 0.4
    private static let spacing: CGFloat = 16

    let title: LocalizedStringResource

    init(_ title: LocalizedStringResource) {
        self.title = title
    }

    var body: some View {
        VStack(spacing: Self.spacing) {
            Image(.emptyStateMark)
                .resizable()
                .renderingMode(.template)
                .scaledToFit()
                .frame(maxHeight: Self.markHeight)
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
    EmptyStateView(.commonZeroBalances)
        .frame(width: 800, height: 500)
}
