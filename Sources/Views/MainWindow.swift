//
//  MainWindow.swift
//  Reefr Wallet
//
//  Created by Andrey Yurkevich on 23.11.26.
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import SwiftUI

/// The macOS main window, which presents dApp prompts as sheets: one arriving while it's closed
/// reopens it.
@MainActor
enum MainWindow {
    static let id = "main"

#if os(macOS)
    private static var isOpen = false
    private static var openWindow: OpenWindowAction?

    static func showIfClosed() {
        guard !isOpen, let openWindow else {
            return
        }

        Logger.verbose("Reopening the main window for a dApp prompt")
        openWindow(id: id)
    }

    fileprivate static func appeared(_ action: OpenWindowAction) {
        openWindow = action
        isOpen = true
    }

    fileprivate static func disappeared() {
        isOpen = false
    }
#endif
}

extension View {
    /// Marks the view as the main window's content.
    func mainWindowContent() -> some View {
        modifier(MainWindowContent())
    }
}

private struct MainWindowContent: ViewModifier {
#if os(macOS)
    @Environment(\.openWindow) private var openWindow
#endif

    func body(content: Content) -> some View {
#if os(macOS)
        content
            .onAppear { MainWindow.appeared(openWindow) }
            .onDisappear { MainWindow.disappeared() }
#else
        content
#endif
    }
}
