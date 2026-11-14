//
//  AccountFiltersView.swift
//  Reefr Wallet
//
//  Created by Andrey Yurkevich on 03.11.26.
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import SwiftUI

#if os(iOS)
/// iOS filters sheet: Addressed checks and token switches.
struct AccountFiltersView: View {
    let tab: AccountTab

    @Binding var filter: AccountFilter

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                switch tab {
                case .addresses, .approvals, .staking, .tokens:
                    EmptyView()

                case .balances:
                    Section {
                        Toggle(.accountDetailsHideUnknownTokens, isOn: $filter.hideUnknownTokens)
                        Toggle(.accountDetailsHideZeroBalances, isOn: $filter.hideZeroBalances)
                    }

                case .transactions:
                    Section {
                        check(.accountDetailsToMyAccounts, \.toMyAccounts)
                        check(.accountDetailsFromMyAccounts, \.fromMyAccounts)
                    } header: {
                        Text(.accountDetailsAddressed)
                    }
                }
            }
            .navigationTitle(.accountDetailsFilters)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "checkmark")
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityLabel(.commonDone)
                    .accessibilityIdentifier("account-filters-done")
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func check(_ title: LocalizedStringResource, _ keyPath: WritableKeyPath<AccountFilter, Bool>) -> some View {
        Button {
            filter[keyPath: keyPath].toggle()
        } label: {
            HStack {
                Text(title)
                    .foregroundStyle(.primary)

                Spacer()

                if filter[keyPath: keyPath] {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.tint)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
#endif
