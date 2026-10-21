import SwiftUI

/// Small trailing "+" button for sidebar section and key store headers.
struct SidebarAddButton: View {
    let accessibilityLabel: LocalizedStringKey
    let accessibilityId: String
    /// Key store headers render as rows that sit ~14pt further from the trailing edge than section headers.
    var trailingPadding: CGFloat = 8
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "plus")
                // Fixed size: key store headers use the larger row font.
                .style(.smallIcon, foreground: .sidebarControl)
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .padding(.trailing, trailingPadding)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityIdentifier(accessibilityId)
    }
}
