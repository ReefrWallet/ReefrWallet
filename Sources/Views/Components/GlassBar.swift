//
//  GlassBar.swift
//  Reefr Wallet
//
//  Created by Andrey Yurkevich on 05/11/2026.
//  Copyright © 2025 Reefr Wallet. All rights reserved.
//

#if os(iOS)

import SwiftUI

struct GlassBar<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        if #available(iOS 26.0, *) {
            GlassEffectContainer(spacing: 8) {
                content
            }
        } else {
            content
        }
    }
}

extension View {
    /// Nonisolated, as a modifier, so animation callbacks that SwiftUI runs outside the main actor
    /// can use it; the glass itself is applied in the modifier's main-actor `body`.
    nonisolated func glassCapsule(id: String, in namespace: Namespace.ID) -> some View {
        modifier(GlassCapsule(id: id, namespace: namespace))
    }
}

private struct GlassCapsule: ViewModifier {
    let id: String
    let namespace: Namespace.ID

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content
                .glassEffect(.regular.interactive(), in: .capsule)
                .glassEffectID(id, in: namespace)
                .glassEffectTransition(.matchedGeometry)
        } else {
            content.background(.regularMaterial, in: .capsule)
        }
    }
}

#endif
