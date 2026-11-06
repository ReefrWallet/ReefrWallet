//
//  SidebarSection.swift
//  Reefr Wallet
//
//  Created by Andrey Yurkevich on 06.11.26.
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import SwiftUI

/// Collapsible sidebar section shared by key stores and dApps. Uses the system
/// disclosure for the drop-down animation; on Mac the whole header row reveals
/// the add button on hover.
struct SidebarSection<Add: View, Content: View, Title: View, Trailing: View>: View {
    @Binding var isExpanded: Bool
    @ViewBuilder let add: () -> Add
    @ViewBuilder let content: () -> Content
    @ViewBuilder let title: () -> Title
    @ViewBuilder let trailing: () -> Trailing

    /// The row's trailing edge sits this far inside the unhovered header.
    private static var rowEdgeInset: CGFloat { 9 }

    @State private var headerFrame = CGRect.zero
    /// Measured while not hovered: the header narrows once the system chevron appears.
    @State private var restingMaxX = CGFloat.zero

    @Environment(\.sidebarHoverLocation) private var hoverLocation

    /// Tracked by the list rather than the header: the system chevron sits outside the header
    /// view and would otherwise end the hover.
    private var isHovered: Bool {
        guard let hoverLocation else {
            return false
        }

        return hoverLocation.y >= headerFrame.minY
            && hoverLocation.y <= headerFrame.maxY
            && hoverLocation.x >= headerFrame.minX
            && hoverLocation.x <= restingMaxX - Self.rowEdgeInset
    }

    /// Keeps the header from growing taller on hover when the add button appears.
    @ScaledMetric(relativeTo: .caption) private var controlHeight: CGFloat = 12

    private var animatedExpansion: Binding<Bool> {
        Binding(
            get: { isExpanded },
            set: { newValue in
                withAnimation {
                    isExpanded = newValue
                }
            }
        )
    }

    var body: some View {
        Section(isExpanded: animatedExpansion) {
            content()
        } header: {
            HStack(spacing: isPhone ? 12 : 4) {
                title()

                Spacer()

                trailing()
                    .layoutPriority(1)

#if os(macOS)
                if isHovered {
                    add()
                        .frame(height: controlHeight)
                }
#endif
            }
#if os(macOS)
            // Headers sit ~14pt further right than rows; align with the row trailing edge
            // unless the system chevron is showing.
            .padding(.trailing, isHovered ? 0 : 14)
#endif
            // Fill the whole header cell so its measured frame spans the row height.
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: {
                headerFrame = $0

                if !isHovered {
                    restingMaxX = $0.maxX
                }
            }
        }
    }
}

/// Pointer location inside the sidebar list, shared with its section headers.
enum SidebarHover {
    static let space = "sidebarList"
}

private struct SidebarHoverLocationKey: EnvironmentKey {
    static let defaultValue: CGPoint? = nil
}

extension EnvironmentValues {
    var sidebarHoverLocation: CGPoint? {
        get { self[SidebarHoverLocationKey.self] }
        set { self[SidebarHoverLocationKey.self] = newValue }
    }
}
