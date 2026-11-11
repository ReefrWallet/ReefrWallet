//
//  PhraseGridLayout.swift
//  Reefr Wallet
//
//  Created by Andrey Yurkevich on 11.11.26.
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import SwiftUI

/// Marks the subview that is a bare caret between two cells (an empty
/// editor in the middle of the phrase). It takes no cell: neighbors keep
/// their places and the caret sits in the gap before the next cell.
struct IsCaretKey: LayoutValueKey {
    static let defaultValue = false
}

/// Lays cells out in `columns` equal columns, aligned by leading edge, so
/// a word keeps its column however long it is.
struct PhraseGridLayout: Layout {
    var columns: Int
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 320
        let cells = subviews.filter { !$0[IsCaretKey.self] }
        let rows = max(1, (cells.count + columns - 1) / columns)
        let rowHeight = self.rowHeight(of: cells, cellWidth: cellWidth(in: width))

        return CGSize(width: width, height: CGFloat(rows) * rowHeight + CGFloat(rows - 1) * spacing)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let cellWidth = cellWidth(in: bounds.width)
        let cells = subviews.filter { !$0[IsCaretKey.self] }
        let rowHeight = rowHeight(of: cells, cellWidth: cellWidth)
        var cellIndex = 0

        for subview in subviews {
            let row = CGFloat(cellIndex / columns)
            let column = CGFloat(cellIndex % columns)
            let y = bounds.minY + row * (rowHeight + spacing)

            if subview[IsCaretKey.self] {
                let x = bounds.minX + column * (cellWidth + spacing) - (column == 0 ? 0 : spacing / 2)
                subview.place(
                    at: CGPoint(x: x, y: y),
                    anchor: .topLeading,
                    proposal: ProposedViewSize(width: 2, height: rowHeight)
                )
            } else {
                let x = bounds.minX + column * (cellWidth + spacing)
                subview.place(
                    at: CGPoint(x: x, y: y),
                    anchor: .topLeading,
                    proposal: ProposedViewSize(width: cellWidth, height: rowHeight)
                )

                cellIndex += 1
            }
        }
    }

    private func cellWidth(in width: CGFloat) -> CGFloat {
        (width - spacing * CGFloat(columns - 1)) / CGFloat(columns)
    }

    private func rowHeight(of cells: [LayoutSubview], cellWidth: CGFloat) -> CGFloat {
        cells.map { $0.sizeThatFits(ProposedViewSize(width: cellWidth, height: nil)).height }.max() ?? 25
    }
}
