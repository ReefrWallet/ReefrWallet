//
//  HardwareKeyPromptHUD.swift
//  Reefr Wallet
//
//  Created by Andrey Yurkevich on 21.10.26.
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import SwiftUI

// MARK: - HostedPrompt

/// What a prompt host presents: a hardware key prompt, or else its own
/// operation's progress.
enum HostedPrompt: Equatable, Identifiable {
    /// The operation finished; shown briefly before the popup is dismissed.
    case complete(String)
    case hardware(HardwareKeyPrompt)
    case progress(String)

    /// One id, so switching between cases updates the sheet in place.
    var id: String {
        "prompt"
    }

    var isCancellable: Bool {
        guard case let .hardware(prompt) = self else {
            return false
        }

        return prompt.kind == .connect
    }

    var isRotating: Bool {
        switch self {
        case .complete: false
        case let .hardware(prompt): prompt.kind == .wait
        case .progress: true
        }
    }

    var message: String {
        switch self {
        case let .complete(message): message
        case let .hardware(prompt): prompt.message
        case let .progress(message): message
        }
    }

    var systemImage: String {
        switch self {
        case .complete: "checkmark.circle"
        case let .hardware(prompt): prompt.systemImage
        case .progress: "progress.indicator"
        }
    }
}

// MARK: - HardwareKeyPromptHUD

/// Asks the user to act on a hardware key, or shows progress, while an
/// operation runs. Styled after Xcode's "Build Succeeded" HUD.
struct HardwareKeyPromptHUD: View {
    let prompt: HostedPrompt
    let onCancel: () -> Void

    private static let cornerRadius: CGFloat = 20

    var body: some View {
        VStack(spacing: 14) {
            let image = Image(systemName: prompt.systemImage)
                .resizable()
                .scaledToFit()
                .style(foreground: .secondary)
                // Shrinks to fit longer messages in the fixed square.
                .frame(maxWidth: 96, maxHeight: 96)
                .contentTransition(.symbolEffect(.replace))

            if prompt.isRotating {
                image.symbolEffect(.rotate.byLayer, options: .repeat(.continuous))
            } else if case .complete = prompt {
                image.symbolEffect(.bounce, options: .nonRepeating, isActive: true)
            } else {
                image.symbolEffect(.breathe)
            }

            Text(prompt.message)
                .style(.hud, foreground: .primary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .layoutPriority(1)
                .accessibilityIdentifier("hardware-key-prompt-message")

            if prompt.isCancellable {
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(16)
        .frame(width: 200, height: 200)
        .hudBackground(cornerRadius: Self.cornerRadius)
        .animation(.default, value: prompt)
    }
}

private extension View {
    /// Liquid Glass on macOS/iOS 26+, a material with a hairline border before.
    @ViewBuilder
    func hudBackground(cornerRadius: CGFloat) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if #available(iOS 26, macOS 26, *) {
            glassEffect(.regular, in: shape)
        } else {
            background(.thickMaterial, in: shape)
                .overlay {
                    shape.strokeBorder(.white.opacity(0.1))
                }
        }
    }
}

// MARK: - HardwareKeyPromptHost

/// Overlays ``HardwareKeyPromptHUD`` on this view while it's the topmost
/// host. An overlay, not a sheet: a sheet is a separate window, so its glass
/// can't show the content behind it.
private struct HardwareKeyPromptHost: ViewModifier {
    /// Shown while no hardware key prompt is up.
    let progress: HostedPrompt?

    @State private var hostId = UUID()

    private let promptCenter = DI.injectOrFail(HardwareService.self).promptCenter

    func body(content: Content) -> some View {
        let prompt = presentedPrompt

        content
            // Also disables keyboard shortcuts underneath, e.g. Esc.
            .disabled(prompt != nil)
            .overlay {
                if let prompt {
                    ZStack {
                        // Blocks clicks on the content underneath.
                        Color.clear
                            .contentShape(Rectangle())

                        HardwareKeyPromptHUD(prompt: prompt) {
                            promptCenter.cancel()
                        }
                    }
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
                }
            }
            .animation(.default, value: prompt == nil)
            .onAppear {
                promptCenter.addHost(hostId)
            }
            .onDisappear {
                promptCenter.removeHost(hostId)
            }
    }

    private var presentedPrompt: HostedPrompt? {
        guard promptCenter.topHostId == hostId else {
            return nil
        }

        return promptCenter.prompt.map(HostedPrompt.hardware) ?? progress
    }
}

extension View {
    /// Lets hardware key prompts present on top of this view. Apply to
    /// window roots and to any sheet open while a hardware key is in use.
    ///
    /// - Parameter progress: The `.progress` or `.complete` prompt to
    ///   present while no hardware key prompt is up; `nil` presents nothing.
    func hardwareKeyPromptHost(progress: HostedPrompt? = nil) -> some View {
        modifier(HardwareKeyPromptHost(progress: progress))
    }
}

// MARK: - Preview

#Preview("Complete") {
    HardwareKeyPromptHUD(prompt: .complete("Complete")) {}
        .padding()
}

#Preview("Confirm") {
    HardwareKeyPromptHUD(prompt: .hardware(HardwareKeyPrompt(vendorName: "Trezor", kind: .confirm))) {}
        .padding()
}

#Preview("Connect") {
    HardwareKeyPromptHUD(prompt: .hardware(HardwareKeyPrompt(vendorName: "Trezor", kind: .connect))) {}
        .padding()
}

#Preview("Progress") {
    HardwareKeyPromptHUD(prompt: .progress("Signing")) {}
        .padding()
}

#Preview("Wait") {
    HardwareKeyPromptHUD(prompt: .hardware(HardwareKeyPrompt(vendorName: "Trezor", kind: .wait))) {}
        .padding()
}
