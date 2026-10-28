import SwiftUI

/// `true` only on iPhone; iPad and Mac keep the sidebar/table layouts.
var isPhone: Bool {
#if os(iOS)
    UIDevice.current.userInterfaceIdiom == .phone
#else
    false
#endif
}

extension View {
    /// Keeps the iPhone row card unhighlighted while its selection lingers during the back animation.
    @ViewBuilder
    func phoneRowNeverHighlighted() -> some View {
#if os(iOS)
        if isPhone {
            listRowBackground(Color(uiColor: .secondarySystemGroupedBackground))
        } else {
            self
        }
#else
        self
#endif
    }

    /// Inset-grouped cards on iPhone; leaves other platforms' list style untouched.
    @ViewBuilder
    func phoneInsetGroupedListStyle() -> some View {
#if os(iOS)
        if isPhone {
            listStyle(.insetGrouped)
        } else {
            self
        }
#else
        self
#endif
    }
}

extension Color {
    /// Fixed colors: `.primary`/`.secondary` flip to the selection tint while a list row stays selected during the back animation.
    static var phoneLabel: Color {
#if os(iOS)
        Color(uiColor: .label)
#else
            .primary
#endif
    }

    static var phoneSecondaryLabel: Color {
#if os(iOS)
        Color(uiColor: .secondaryLabel)
#else
            .secondary
#endif
    }
}
