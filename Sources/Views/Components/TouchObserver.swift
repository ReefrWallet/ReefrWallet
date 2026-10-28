//
//  TouchObserver.swift
//  Reefr Wallet
//
//  Created by Andrey Yurkevich on 02.11.26.
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import SwiftUI

#if os(iOS)
import UIKit

extension View {
    /// Calls `action` when any touch begins outside a text input, whatever it lands on
    /// (empty space, controls, menus). The touch is still delivered normally.
    func onTouchOutsideTextInput(perform action: @escaping () -> Void) -> some View {
        background(TouchObserver(action: action))
    }
}

private struct TouchObserver: UIViewRepresentable {
    let action: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(action: action)
    }

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.isUserInteractionEnabled = false
        context.coordinator.view = view

        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.action = action
        context.coordinator.attachIfNeeded()
    }

    static func dismantleUIView(_ uiView: UIView, coordinator: Coordinator) {
        coordinator.detach()
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var action: () -> Void
        weak var view: UIView?
        private weak var window: UIWindow?

        private lazy var recognizer: UILongPressGestureRecognizer = {
            let recognizer = UILongPressGestureRecognizer(target: self, action: #selector(handle))
            recognizer.minimumPressDuration = 0
            recognizer.cancelsTouchesInView = false
            recognizer.delaysTouchesBegan = false
            recognizer.delaysTouchesEnded = false
            recognizer.delegate = self

            return recognizer
        }()

        init(action: @escaping () -> Void) {
            self.action = action
        }

        func attachIfNeeded() {
            // The window is available only after the view is installed.
            DispatchQueue.main.async { [weak self] in
                guard let self, let window = view?.window, window !== self.window else {
                    return
                }

                self.window?.removeGestureRecognizer(recognizer)
                window.addGestureRecognizer(recognizer)
                self.window = window
            }
        }

        func detach() {
            window?.removeGestureRecognizer(recognizer)
            window = nil
        }

        @objc
        private func handle(_ recognizer: UILongPressGestureRecognizer) {
            guard recognizer.state == .began else {
                return
            }

            action()
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldReceive touch: UITouch
        ) -> Bool {
            var view = touch.view

            while let current = view {
                if current is UITextField || current is UITextView {
                    return false
                }

                view = current.superview
            }

            return true
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
        ) -> Bool {
            true
        }
    }
}

#else

extension View {
    func onTouchOutsideTextInput(perform action: @escaping () -> Void) -> some View {
        self
    }
}

#endif
