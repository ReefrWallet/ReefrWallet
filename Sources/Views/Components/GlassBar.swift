//
//  GlassBar.swift
//  Reefr Wallet
//
//  Created by Andrey Yurkevich on 05/11/2026.
//  Copyright © 2025 Reefr Wallet. All rights reserved.
//

#if os(iOS)

private struct GlassBar<Content: View>: View {
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

private extension View {
    @ViewBuilder
    func glassCapsule(id: String, in namespace: Namespace.ID) -> some View {
        if #available(iOS 26.0, *) {
            glassEffect(.regular.interactive(), in: .capsule)
                .glassEffectID(id, in: namespace)
                .glassEffectTransition(.matchedGeometry)
        } else {
            background(.regularMaterial, in: .capsule)
        }
    }
}

#endif
