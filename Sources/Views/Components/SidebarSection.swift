//
//  SidebarSection.swift
//  Reefr Wallet
//
//  Created by Andrey Yurkevich on 06.11.26.
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import Combine
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

#if os(macOS)
    @Environment(\.sidebarHover) private var hover
    @State private var headerFrame = CGRect.zero
    @State private var isHovered = false
    /// Measured while not hovered: the header narrows once the system chevron appears.
    @State private var restingMaxX = CGFloat.zero

    /// Keeps the header from growing taller on hover when the add button appears.
    @ScaledMetric(relativeTo: .caption) private var controlHeight: CGFloat = 12
#endif

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
#if os(macOS)
            .onReceive(hover?.location.eraseToAnyPublisher() ?? Empty().eraseToAnyPublisher()) { location in
                updateHover(location)
            }
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: {
                headerFrame = $0

                if !isHovered {
                    restingMaxX = $0.maxX
                }

                updateHover(hover?.location.value)
            }
#endif
        }
    }

#if os(macOS)
    private func updateHover(_ location: CGPoint?) {
        // Use the resting width so the system chevron can appear without ending the hover.
        let hitArea = CGRect(
            x: headerFrame.minX,
            y: headerFrame.minY,
            width: max(0, restingMaxX - headerFrame.minX - 9),
            height: headerFrame.height
        )

        let hovered = location.map(hitArea.contains) ?? false
        if hovered != isHovered {
            isHovered = hovered
        }
    }
#endif
}

#if os(macOS)
/// Publishes pointer moves without invalidating the sidebar's view hierarchy.
final class SidebarHover {
    let location = CurrentValueSubject<CGPoint?, Never>(nil)
}

extension EnvironmentValues {
    @Entry var sidebarHover: SidebarHover?
}
#endif
