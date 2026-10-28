import SwiftUI

/// Small trailing "+" button for sidebar section and key store headers.
struct SidebarAddButton: View {
    let accessibilityLabel: LocalizedStringResource
    let accessibilityId: String
    /// Key store headers render as rows that sit ~14pt further from the trailing edge than section headers.
    var trailingPadding: CGFloat = 8
    let action: () -> Void

    @Environment(\.isEnabled) private var isEnabled

    /// Section headers inset like rows on iPhone, so match the key store rows' padding there.
    static var headerTrailingPadding: CGFloat { isPhone ? -6 : 8 }

    var body: some View {
        Button(action: action) {
            Image(systemName: "plus")
                // Fixed size: key store headers use the larger row font.
                .style(.smallIcon, foreground: .sidebarControl)
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .opacity(isEnabled ? 1 : 0.3)
        .padding(.trailing, trailingPadding)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityIdentifier(accessibilityId)
    }
}
