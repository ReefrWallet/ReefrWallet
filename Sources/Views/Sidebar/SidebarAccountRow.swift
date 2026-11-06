import SwiftUI

/// Narrow, value-type inputs so SwiftUI can skip re-running `body` (and
/// re-touching `account.blockchain`, a SwiftData relationship fault +
/// decode) for rows whose selection/editing state didn't change.
struct SidebarAccountRow: View {
    let account: AccountModel
    @Binding var editingName: String

    let isEditing: () -> Bool
    let isSelected: () -> Bool
    let onSelect: () -> Void
    let onStartEditing: () -> Void
    let onCommitEditing: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            label

            Spacer()

            Text("\(account.usdValue().formattedAbbreviated(fractionLength: 0)) US$")
                .style(.small, foreground: isSelected() ? .white : .sidebarSecondaryLabel)
        }
    }

    private var label: some View {
        Label {
            if isEditing() {
                TextField(account.name, text: $editingName)
                    .textFieldStyle(.plain)
                    .onSubmit(onCommitEditing)
                    .accessibilityIdentifier("sidebar-account-textfield-\(account.name)")
            } else {
                // `.onTapGesture`, not `Button`: a `Button` inside a macOS
                // `List` row needs an extra click just to make the row/List
                // the key view before its action fires, so the click right
                // after selecting only shows the press effect and does
                // nothing — a third click would be needed to actually start
                // editing. `.onTapGesture` fires on that very next click.
                // It's still race-free: this gesture is unconditionally
                // present whenever not editing, regardless of selection —
                // only the *behavior* branches on the live `isSelected()`
                // read inside the handler.
                Text(account.name)
                    .style(foreground: isSelected() ? .white : .sidebarLabel)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        if isSelected() {
                            onStartEditing()
                        } else {
                            onSelect()
                        }
                    }
                    .accessibilityIdentifier("sidebar-account-label-\(account.name)")
            }
        } icon: {
            account.blockchain.blockchain.logoImage
                .resizable()
                .scaledToFit()
                .frame(width: 16, height: 16)
        }
    }
}
