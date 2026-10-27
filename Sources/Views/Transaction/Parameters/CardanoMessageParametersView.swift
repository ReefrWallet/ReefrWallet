//
//  CardanoMessageParametersView.swift
//  Reefr Wallet
//
//  Created by Andrey Yurkevich on 27.10.26.
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import Foundation
import SwiftUI

/// A CIP-8 `signData` request: site and account, which key signs for the
/// address the dapp named, then the payload.
struct CardanoMessageParametersView: View {
    let account: Account
    let keyRole: CardanoKeyRole
    let message: Data
    let site: String

    var body: some View {
#if os(macOS)
        ParameterSection {
            ParameterRow("Site", value: site)
        }

        ParameterSection {
            FromRow(account: account, title: "Account")
            signsWithRow
        }
#else
        ParameterSection {
            ParameterRow("Site", value: site)
            FromRow(account: account, title: "Account")
            signsWithRow
        }
#endif

        ParameterBlock("Message", text: String(data: message, encoding: .utf8) ?? message.hexEncoded)
    }

    private var signsWithRow: some View {
        ParameterRow("Signs with", value: Self.keyName(keyRole))
    }

    static func keyName(_ role: CardanoKeyRole) -> String {
        switch role {
        case .payment: "Payment key"
        case .stake: "Stake key"
        }
    }
}
