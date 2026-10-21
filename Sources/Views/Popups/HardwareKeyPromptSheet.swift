//
//  HardwareKeyPromptSheet.swift
//  Reefr Wallet
//
//  Created by Andrey Yurkevich on 21.10.26.
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import SwiftUI

// MARK: - HardwareKeyPromptSheet

/// Asks the user to act on a hardware key while an operation waits on it.
struct HardwareKeyPromptSheet: View {
    let prompt: HardwareKeyPrompt
    let onCancel: () -> Void

    var body: some View {
        VStack {
            let image = Image(systemName: prompt.systemImage)
                .resizable()
                .scaledToFit()
                .style(foreground: .secondary)
                .frame(width: 64, height: 64)
                .padding(.bottom)

            if prompt.kind == .wait {
                image.symbolEffect(.rotate.byLayer, options: .repeat(.continuous))
            } else {
                image.symbolEffect(.breathe)
            }

            Text(prompt.message)
                .style(.large, foreground: .primary)
                .accessibilityIdentifier("hardware-key-prompt-message")

            if prompt.kind == .connect {
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                    .padding(.top)
            }
        }
        .padding(20)
        .frame(minWidth: 320)
        .interactiveDismissDisabled()
    }
}

// MARK: - HardwareKeyPromptHost

/// Presents ``HardwareKeyPromptSheet`` from this view while it's the
/// topmost host.
private struct HardwareKeyPromptHost: ViewModifier {
    @State private var hostId = UUID()

    private let promptCenter = DI.injectOrFail(HardwareService.self).promptCenter

    func body(content: Content) -> some View {
        content
            .onAppear {
                promptCenter.addHost(hostId)
            }
            .onDisappear {
                promptCenter.removeHost(hostId)
            }
            .sheet(item: promptBinding) { prompt in
                HardwareKeyPromptSheet(prompt: prompt) {
                    promptCenter.cancel()
                }
            }
    }

    private var promptBinding: Binding<HardwareKeyPrompt?> {
        Binding(
            get: { promptCenter.topHostId == hostId ? promptCenter.prompt : nil },
            set: { _ in }
        )
    }
}

extension View {
    /// Lets hardware key prompts present on top of this view. Apply to
    /// window roots and to any sheet open while a hardware key is in use.
    func hardwareKeyPromptHost() -> some View {
        modifier(HardwareKeyPromptHost())
    }
}

// MARK: - Preview

#Preview("Confirm") {
    HardwareKeyPromptSheet(prompt: HardwareKeyPrompt(keyName: "Trezor #1", kind: .confirm)) {}
}

#Preview("Connect") {
    HardwareKeyPromptSheet(prompt: HardwareKeyPrompt(keyName: "Trezor #1", kind: .connect)) {}
}

#Preview("Wait") {
    HardwareKeyPromptSheet(prompt: HardwareKeyPrompt(keyName: "Trezor #1", kind: .wait)) {}
}
