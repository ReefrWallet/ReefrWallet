//
//  SelectionGroupView.swift
//  Reefr Wallet
//
//  Created by Andrey Yurkevich on 06.01.26.
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import SwiftUI

// MARK: - SelectionOption

struct SelectionOption: Identifiable {
    let id: String
    let title: String
    let image: Image?

    init(id: String = UUID().uuidString, title: String, image: Image? = nil) {
        self.id = id
        self.title = title
        self.image = image
    }
}

// MARK: - SelectionGroupView

struct SelectionGroupView: View {
    var options: [SelectionOption]
    @Binding var selectedOption: String?

    var body: some View {
        VStack {
            ForEach(options) { option in
                Button {
                    Task { @MainActor in
                        selectedOption = option.id
                    }
                } label: {
                    HStack {
                        if let image = option.image {
                            image
                                .resizable()
                                .scaledToFit()
                                .frame(width: 16, height: 16)
                        }

                        Text(option.title)
                    }
                    .frame(maxWidth: .infinity)
                    .padding()
                }
                .tint(selectedOption == option.id ? .accentColor : .primary)
            }
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Preview

#if DEBUG

#Preview {
    @Previewable @State var selectedOption: String?

    SelectionGroupView(
        options: [
            SelectionOption(title: "Option 1", image: Image(systemName: "star")),
            SelectionOption(title: "Option 2", image: Image(systemName: "heart")),
            SelectionOption(title: "Option 3", image: Image(systemName: "circle"))
        ],
        selectedOption: $selectedOption
    )
    .padding()
}

#endif
