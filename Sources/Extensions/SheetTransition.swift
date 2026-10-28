//
//  SheetTransition.swift
//  Reefr Wallet
//
//  Created by Andrey Yurkevich on 03.11.26.
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import SwiftUI

extension EnvironmentValues {
    /// Namespace shared by sheet source buttons and the sheets that zoom out of them.
    @Entry var sheetNamespace: Namespace.ID?
}

extension View {
    /// Marks the view as the origin of the sheet with `id`, so the sheet zooms out of it (iOS and iPadOS).
    @ViewBuilder
    func sheetSource(_ id: String) -> some View {
#if os(iOS)
        modifier(SheetSourceModifier(id: id))
#else
        self
#endif
    }

    /// Makes a sheet's content zoom out of the view marked with ``sheetSource(_:)``.
    @ViewBuilder
    func sheetZoom(from id: String, namespace: Namespace.ID?) -> some View {
#if os(iOS)
        if let namespace {
            navigationTransition(.zoom(sourceID: id, in: namespace))
        } else {
            self
        }
#else
        self
#endif
    }
}

#if os(iOS)
private struct SheetSourceModifier: ViewModifier {
    let id: String

    @Environment(\.sheetNamespace) private var namespace

    func body(content: Content) -> some View {
        if let namespace {
            content.matchedTransitionSource(id: id, in: namespace)
        } else {
            content
        }
    }
}
#endif

/// Holds the namespace for the subtree below.
struct SheetNamespaceHost<Content: View>: View {
    @Namespace private var namespace

    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .environment(\.sheetNamespace, namespace)
    }
}
