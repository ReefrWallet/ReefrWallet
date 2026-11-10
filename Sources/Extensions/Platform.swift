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

#if os(macOS)
extension View {
    /// Status bar with the toolbar's scroll edge effect on macOS 26+.
    /// Content under a top bar grows transparent toward the top edge, hiding the container's hard edge.
    func statusBar(
        edge: VerticalEdge = .bottom,
        background: Color = Color(nsColor: .windowBackgroundColor),
        @ViewBuilder content: () -> some View
    ) -> some View {
        modifier(StatusBarModifier(background: background, bar: content(), edge: edge))
    }
}

private struct StatusBarModifier<Bar: View>: ViewModifier {
    let background: Color
    let bar: Bar
    let edge: VerticalEdge

    @State private var barHeight: CGFloat = 0

    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content
                .mask {
                    if edge == .top {
                        topFadeMask
                            .ignoresSafeArea()
                    } else {
                        Color.black
                            .ignoresSafeArea()
                    }
                }
                .safeAreaBar(edge: edge, spacing: 0) {
                    bar
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { barHeight = $0 }
                }
                .scrollEdgeEffectStyle(.soft, for: edge == .top ? .top : .bottom)
        } else {
            content
                .safeAreaInset(edge: edge, spacing: 0) {
                    bar
                        .background(background)
                }
        }
    }

    private var topFadeMask: some View {
        VStack(spacing: 0) {
            LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
                .frame(height: barHeight)

            Color.black
        }
    }
}
#endif
