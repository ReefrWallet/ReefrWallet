//
//  AddressBookView.swift
//  Reefr Wallet
//
//  Created by Andrey Yurkevich on 22.02.26.
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import SwiftData
import SwiftUI
import WalletKit

struct AddressBookView {
    private let isSelectable: Bool

    @Binding private var selectedAddress: String?

    @State private var isAddressBookPresented: Bool = false
    @State private var selection: PersistentIdentifier?

    @Query
    private var savedAddresses: [SavedAddressModel]

    @Environment(\.dismiss) var dismiss

    private let blockchain: Blockchain

    init(blockchain: Blockchain, selectedAddress: Binding<String?>? = nil) {
        self.blockchain = blockchain

        if let selectedAddress {
            _selectedAddress = selectedAddress
            isSelectable = true
        } else {
            _selectedAddress = .constant(nil)
            isSelectable = false
        }
    }
}

extension AddressBookView: View {
    var body: some View {
        VStack {
            Table(of: SavedAddressModel.self, selection: $selection) {
                TableColumn("Address", value: \.address)
                TableColumn("Memo", value: \.memo)
            } rows: {
                ForEach(savedAddresses) {
                    TableRow($0)
                }
            }

            Spacer()

            HStack {
                Button("Add New") {
                    isAddressBookPresented = true
                }

                Spacer()

                if isSelectable {
                    Button("Cancel") {
                        dismiss()
                    }

                    Button("Select") {
                        selectedAddress = savedAddresses
                            .first { $0.id == selection }?
                            .address

                        dismiss()
                    }
                } else {
                    Button("Close") {
                        dismiss()
                    }
                }
            }
        }
        .padding()
    }
}

private extension AddressBookView {
}

#Preview {
    AddressBookView(blockchain: .evm(.ethereum(.sepolia)))
        .frame(width: 500)
}
