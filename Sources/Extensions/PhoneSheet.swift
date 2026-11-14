import SwiftUI

extension View {
    /// iPhone sheet chrome: inline title, Cancel on the left, confirm on the right.
    /// A no-op on macOS, where sheets keep their own button rows.
    @ViewBuilder
    func phoneSheet(
        _ title: LocalizedStringResource,
        cancelTitle: LocalizedStringResource = .commonCancel,
        cancelId: String? = nil,
        isCancelDisabled: Bool = false,
        onCancel: @escaping () -> Void,
        confirmTitle: LocalizedStringResource? = nil,
        confirmId: String? = nil,
        confirmRole: ButtonRole? = nil,
        isConfirmEnabled: Bool = true,
        onConfirm: @escaping () -> Void = {}
    ) -> some View {
        #if os(iOS)
        NavigationStack {
            self
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(cancelTitle, action: onCancel)
                            .disabled(isCancelDisabled)
                            .accessibilityIdentifier(cancelId ?? "")
                    }

                    if let confirmTitle {
                        ToolbarItem(placement: .confirmationAction) {
                            Button(confirmTitle, role: confirmRole, action: onConfirm)
                                .tint(confirmRole == .destructive ? .red : nil)
                                .disabled(!isConfirmEnabled)
                                .accessibilityIdentifier(confirmId ?? "")
                        }
                    }
                }
        }
        #else
        self
        #endif
    }
}
