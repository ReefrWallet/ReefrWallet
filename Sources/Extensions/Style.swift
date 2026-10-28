//
//  Style.swift
//  Reefr Wallet
//
//  Created by Andrey Yurkevich on 13.12.25.
//  Copyright © 2025 Reefr Wallet. All rights reserved.
//

import SwiftUI

struct StyledView: ViewModifier {
    private let size: Size?
    private let foregroundColor: Color?
    private let backgroundColor: Color?

    init(
        size: Size? = nil,
        foregroundColor: Color? = nil,
        backgroundColor: Color? = nil
    ) {
        self.size = size
        self.foregroundColor = foregroundColor
        self.backgroundColor = backgroundColor
    }

    func body(content: Content) -> some View {
        content
            .with(size: size)
            .with(foregroundColor: foregroundColor)
            .with(backgroundColor: backgroundColor)
    }
}

extension StyledView {
    enum Size {
        case largeHeader
        case mediumHeader
        case smallHeader
        case large
        case medium
        case small
        /// 13pt, list secondary lines.
        case caption
        /// 15pt, iPad table cells.
        case callout
        /// 17pt semibold, list row titles and amounts.
        case headline
        /// 18pt medium, HUD popup messages.
        case hud
        /// 14pt monospaced, iPad hashes and amounts.
        case mono
        /// 11pt monospaced, Mac hashes and amounts.
        case smallMono
        /// 10pt semibold, sidebar header glyphs.
        case smallIcon
        /// 22pt bold, iPhone list section titles.
        case title
    }
}

extension View {
    func style(
        _ size: StyledView.Size? = nil,
        foreground: Color? = nil,
        background: Color? = nil
    ) -> some View {
        modifier(
            StyledView(
                size: size,
                foregroundColor: foreground,
                backgroundColor: background
            )
        )
    }
}

private extension View {
    @ViewBuilder
    func with(backgroundColor: Color?) -> some View {
        if let backgroundColor {
            backgroundStyle(backgroundColor)
        } else {
            self
        }
    }

    @ViewBuilder
    func with(foregroundColor: Color?) -> some View {
        if let foregroundColor {
            foregroundStyle(foregroundColor)
        } else {
            self
        }
    }

    @ViewBuilder
    func with(size: StyledView.Size?) -> some View {
        switch size {
        case .large:
            font(.system(size: 16, weight: .regular))
        case .largeHeader:
            font(.system(size: 16, weight: .bold))
        case .medium:
            font(.system(size: 14, weight: .regular))
        case .mediumHeader:
            font(.system(size: 14, weight: .bold))
        case .small:
            font(.system(size: 12, weight: .regular))
        case .smallHeader:
            font(.system(size: 12, weight: .bold))
        case .caption:
            font(.system(size: 13, weight: .regular))
        case .callout:
            font(.system(size: 15, weight: .regular))
        case .headline:
            font(.system(size: 17, weight: .semibold))
        case .hud:
            font(.system(size: 18, weight: .medium))
        case .mono:
            font(.system(size: 14, weight: .regular, design: .monospaced))
        case .smallMono:
            font(.system(size: 11, weight: .regular, design: .monospaced))
        case .smallIcon:
            font(.system(size: 10, weight: .semibold))
        case .title:
            font(.system(size: 22, weight: .bold))
        case .none:
            self
        }
    }
}
