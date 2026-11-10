import SwiftUI

/// Red "remove" / green "add" circle shown in the iPhone sidebar's edit mode.
struct EditModeButton: View {
    enum Kind {
        case add
        case remove
    }

    let kind: Kind
    let accessibilityLabel: LocalizedStringResource
    /// Shown next to the glyph and making the whole row the tap target.
    var title: LocalizedStringResource?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: kind == .add ? "plus.circle.fill" : "minus.circle.fill")
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, kind == .add ? Color.green : Color.red)
                    .font(.system(size: 22))

                if let title {
                    Text(title)
                        .style(.large, foreground: .phoneLabel)

                    Spacer()
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(accessibilityLabel)
    }
}

/// iPhone/iPad account row: network glyph, name, USD value, disclosure.
/// In edit mode a remove button replaces the disclosure-driven navigation.
struct KeyStoreAccountRow: View {
    let account: AccountModel
    var isEditing = false
    var onRemove: () -> Void = {}

    var body: some View {
        HStack(spacing: 12) {
            if isEditing {
                EditModeButton(kind: .remove, accessibilityLabel: .commonRemove, action: onRemove)
                    .transition(.move(edge: .leading).combined(with: .opacity))
            }

            account.blockchain.blockchain.logoImage
                .resizable()
                .scaledToFit()
                .frame(width: 24, height: 24)

            Text(verbatim: account.name)
                .style(.large, foreground: .phoneLabel)

            Spacer()

            if !isEditing {
                Text("\(account.usdValue().formattedAbbreviated()) US$")
                    .style(.large, foreground: .phoneSecondaryLabel)

                Image(systemName: "chevron.right")
                    .style(.smallIcon, foreground: .phoneSecondaryLabel)
            }
        }
        .contentShape(Rectangle())
    }
}
