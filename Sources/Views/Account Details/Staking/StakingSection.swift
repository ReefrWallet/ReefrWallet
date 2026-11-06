//
//  StakingSection.swift
//  Reefr Wallet
//
//  Created by Andrey Yurkevich on 05.11.26.
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import SwiftUI

// MARK: - StakingRow

struct StakingRow: Identifiable {
    let id: String
    let leading: String
    var secondary: String?
    let trailing: String
    var trailingColor: Color = .primary
    /// 0...1 fills a bar between the two texts.
    var progress: Double?
    /// Makes the trailing text a link.
    var onTrailingTap: (() -> Void)?
}

// MARK: - StakingSection

/// A title above a rounded group of rows, with an optional action (and a
/// caution note) below it, as in dApp settings.
struct StakingSection: View {
    struct Action {
        let title: LocalizedStringResource
        let isProminent: Bool
        let perform: () -> Void
    }

    /// `nil` for a note with no header of its own.
    var title: LocalizedStringResource?
    let rows: [StakingRow]
    var note: String?
    var action: Action?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let title {
                Text(title)
                    .style(isPhone ? .sectionHeader : .mediumHeader, foreground: .primary)
                    .padding(.leading, isPhone ? 16 : 12)
            }

            if !rows.isEmpty {
                // One grid per card: its columns are as wide as the widest label and value of
                // any row, so every bar has the same length and the same gap on both sides.
                Grid(horizontalSpacing: 12, verticalSpacing: 0) {
                    ForEach(rows) { row in
                        if row.id != rows.first?.id {
                            Divider()
                        }

                        gridRow(row)
                    }
                }
                .style(isPhone ? .body : .medium, foreground: nil)
                .padding(.horizontal, isPhone ? 16 : 12)
                .background(Self.cardColor, in: RoundedRectangle(cornerRadius: 10))
            }

            if note != nil || action != nil {
                HStack {
                    if let note {
                        Text(note)
                            .style(isPhone ? .caption : .small, foreground: .caution)
                            // Lines up with the title and the rows' text.
                            .padding(.leading, isPhone ? 0 : 12)
                    }

                    Spacer()

                    if let action {
                        actionButton(action)
                    }
                }
                .padding(.horizontal, isPhone ? 16 : 0)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func gridRow(_ row: StakingRow) -> some View {
        if let progress = row.progress {
            GridRow {
                leading(row)
                    .gridColumnAlignment(.leading)

                ProgressView(value: min(max(progress, 0), 1))
                    // macOS draws a sliver of fill at 0, so an empty bar gets none.
                    .tint(progress <= 0 ? Color.clear : progress < 0.15 ? Color.caution : Color.green)
                    .frame(maxWidth: .infinity)

                trailing(row)
                    .padding(.vertical, isPhone ? 11 : 6)
                    .gridColumnAlignment(.trailing)
            }
        } else {
            // No bar to line up, so the texts share the row: the secondary one gives way first.
            HStack(spacing: 12) {
                leading(row)

                Spacer(minLength: 0)

                trailing(row)
                    .fixedSize(horizontal: true, vertical: false)
                    .padding(.vertical, isPhone ? 11 : 6)
            }
        }
    }

    private func leading(_ row: StakingRow) -> some View {
        HStack(spacing: 12) {
            Text(row.leading)
                .fixedSize(horizontal: true, vertical: false)

            if let secondary = row.secondary {
                Text(secondary)
                    .lineLimit(1)
                    .style(foreground: .secondary)
            }
        }
        .padding(.vertical, isPhone ? 11 : 6)
    }

    @ViewBuilder
    private func trailing(_ row: StakingRow) -> some View {
        if let onTrailingTap = row.onTrailingTap {
            Button(row.trailing, action: onTrailingTap)
                .buttonStyle(.plain)
                .foregroundStyle(row.trailingColor)
        } else {
            Text(row.trailing)
                .foregroundStyle(row.trailingColor)
        }
    }

    @ViewBuilder
    private func actionButton(_ action: Action) -> some View {
        #if os(macOS)
        if action.isProminent {
            Button(action.title, action: action.perform)
                .buttonStyle(.borderedProminent)
        } else {
            Button(action.title, action: action.perform)
        }
        #else
        Button(action: action.perform) {
            Text(action.title)
                .fontWeight(action.isProminent ? .semibold : .regular)
        }
        #endif
    }

    private static var cardColor: Color {
        #if os(macOS)
        Color(nsColor: .controlBackgroundColor)
        #else
        Color(uiColor: .secondarySystemBackground)
        #endif
    }
}

extension View {
    /// The summary's list row on iPhone, inset like ``AccountCountLabel``; unchanged on macOS.
    @ViewBuilder
    func summaryRow() -> some View {
        #if os(iOS)
        listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
            .listRowSeparator(.hidden)
        #else
        self
        #endif
    }

    /// One list row without separator or background on iPhone; unchanged on macOS.
    @ViewBuilder
    func stakingRow() -> some View {
        #if os(iOS)
        listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
            .listRowSeparator(.hidden)
        #else
        self
        #endif
    }
}
